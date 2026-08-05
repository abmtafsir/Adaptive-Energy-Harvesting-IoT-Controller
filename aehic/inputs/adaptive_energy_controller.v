// =====================================================================
// Project      : Adaptive Energy Harvesting IoT Controller (AEHIC)
// Top module   : adaptive_energy_controller
// Description  : Digital ASIC that monitors harvested/battery energy,
//                predicts near-future energy availability using an FSM,
//                and adaptively schedules CPU/radio/sensor activity and
//                duty cycling to maximize battery life.
// Technology   : IHP SG13G2 (130nm) Open PDK / OpenROAD flow
// Language     : Verilog-2001 (strictly synthesizable subset)
// Clocking     : Single clock domain, single asynchronous active-low
//                reset (synchronized internally), clock-enable style
//                gating only (no generated/gated clocks).
// Target Fmax  : 100 MHz
// =====================================================================

module adaptive_energy_controller (
    // -----------------------------------------------------------------
    // Clock / Reset
    // -----------------------------------------------------------------
    input  wire        clk,
    input  wire        rst_n,

    // -----------------------------------------------------------------
    // Sensor / Energy Inputs
    // -----------------------------------------------------------------
    input  wire [11:0] solar_energy_level,
    input  wire [11:0] battery_level,
    input  wire [11:0] temperature_sensor,
    input  wire [11:0] humidity_sensor,
    input  wire        motion_detect,
    input  wire        harvest_valid,
    input  wire        uart_rx,

    // -----------------------------------------------------------------
    // Outputs
    // -----------------------------------------------------------------
    output wire        uart_tx,
    output wire        system_active,
    output wire        sensor_enable,
    output wire        cpu_enable,
    output wire        radio_enable,
    output wire        low_power_mode,
    output wire        sleep_mode,
    output wire        battery_warning,
    output wire [7:0]  energy_prediction,
    output wire [31:0] debug_bus
);

    // =====================================================================
    // 0. GLOBAL PARAMETERS
    // =====================================================================
    parameter CLK_FREQ_HZ        = 100_000_000;
    parameter UART_BAUD          = 115_200;
    // Baud tick divisor : 100MHz / 115200 ~= 868
    localparam integer UART_DIV  = CLK_FREQ_HZ / UART_BAUD;

    // Energy thresholds (12-bit domain, 0..4095)
    // NOTE: these constants are deliberately chosen so that no trailing
    // bit of the threshold is redundant for its comparison direction
    // (i.e. avoid C[k:0]==all-1s for '>' compares or C[k:0]==all-0s
    // for '<' compares) -- such a corner case makes the corresponding
    // low-order bits of the compared signal provably don't-care, which
    // a sufficiently aggressive synthesis pass (e.g. SAT/BDD redundancy
    // removal in the real ORFS/ABC flow) will legitimately prune,
    // leaving that signal's LSBs undriven downstream even though the
    // RTL "uses" them syntactically.
    localparam [11:0] BATTERY_LOW_THRESH     = 12'd401;   // ~10%
    localparam [11:0] BATTERY_CRIT_THRESH    = 12'd151;   // ~4%
    localparam [11:0] SOLAR_LOW_THRESH       = 12'd301;
    localparam [11:0] SOLAR_HIGH_THRESH      = 12'd2500;

    // Prediction-state energy score thresholds (13-bit sum domain)
    localparam [12:0] SCORE_LOW_MAX          = 13'd700;
    localparam [12:0] SCORE_MED_MAX          = 13'd2200;
    localparam [12:0] SCORE_HIGH_MAX         = 13'd3600;

    // Environmental thresholds (12-bit ADC codes, assumed monotonic:
    // higher code = higher temperature / higher relative humidity).
    // PV cell efficiency degrades measurably above ~45 C, and high
    // humidity is used here as a cheap proxy for reduced/variable
    // irradiance (overcast, rain) that should make the predictor more
    // conservative.
    localparam [11:0] TEMP_HIGH_THRESH       = 12'd2866; // ~45 C derate point
    localparam [11:0] HUMIDITY_HIGH_THRESH   = 12'd3000; // ~75% RH

    // =====================================================================
    // 1. RESET SYNCHRONIZER
    // =====================================================================
    reg rst_n_meta, rst_n_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rst_n_meta <= 1'b0;
            rst_n_sync <= 1'b0;
        end else begin
            rst_n_meta <= 1'b1;
            rst_n_sync <= rst_n_meta;
        end
    end

    // =====================================================================
    // 2. ENERGY MONITOR
    //    - Exponential moving average (EMA) of solar level (area-efficient,
    //      uses shift instead of divide)
    //    - Battery percentage approximation
    //    - Average harvested power accumulator
    //    - Threshold detection
    //
    //    IMPLEMENTATION NOTE: the EMA is kept in a 15-bit Q-format
    //    accumulator (integer avg scaled by 8, i.e. avg*8) rather than
    //    directly in a 12-bit register. This lets the full-width raw
    //    sample (solar_energy_level / battery_level) be added into the
    //    accumulator every cycle instead of being pre-shifted by >>3
    //    before it ever reaches a flop -- pre-shifting would silently
    //    and permanently discard each sample's 3 LSBs on every update,
    //    which showed up downstream as those bits having zero fanout
    //    anywhere in the design (dangling top-level input bits in the
    //    physical database, even though nothing was functionally
    //    "wrong"). With the wider accumulator, every sample bit
    //    contributes to accumulator state across cycles, so none of
    //    them are prunable.
    // =====================================================================
    reg  [14:0] solar_avg_acc;      // EMA accumulator for solar (avg*8, Q12.3)
    reg  [14:0] battery_avg_acc;    // EMA accumulator for battery (avg*8, Q12.3)
    wire [11:0] solar_avg;          // EMA of solar_energy_level (integer part)
    wire [11:0] battery_avg;        // EMA of battery_level (integer part)
    reg  [7:0]  battery_pct;        // 0..255 approx percentage
    reg  [15:0] harvest_power_acc;  // accumulated harvested power (windowed)
    reg  [3:0]  harvest_acc_cnt;
    reg  [15:0] avg_harvest_power;  // latched average every window
    wire        harvest_low;
    wire        harvest_high;
    wire        batt_low;
    wire        batt_crit;

    assign solar_avg   = solar_avg_acc[14:3];
    assign battery_avg = battery_avg_acc[14:3];

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            solar_avg_acc   <= 15'd0;
            battery_avg_acc <= 15'd0;
        end else begin
            // avg[n]*8 = avg[n-1]*8 - avg[n-1] + x[n]  (equiv. to the
            // standard alpha=1/8 EMA: avg[n] = avg[n-1]*7/8 + x[n]/8)
            solar_avg_acc   <= solar_avg_acc   - (solar_avg_acc   >> 3) + {3'b000, solar_energy_level};
            battery_avg_acc <= battery_avg_acc - (battery_avg_acc >> 3) + {3'b000, battery_level};
        end
    end

    // Battery percentage: battery_avg (12-bit, max 4095) -> 8-bit (>>4)
    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync)
            battery_pct <= 8'd0;
        else
            battery_pct <= battery_avg[11:4];
    end

    // Windowed average harvested power (16-sample accumulation window)
    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            harvest_power_acc <= 16'd0;
            harvest_acc_cnt   <= 4'd0;
            avg_harvest_power <= 16'd0;
        end else if (harvest_valid) begin
            if (harvest_acc_cnt == 4'd15) begin
                avg_harvest_power <= harvest_power_acc + solar_energy_level;
                harvest_power_acc <= 16'd0;
                harvest_acc_cnt   <= 4'd0;
            end else begin
                harvest_power_acc <= harvest_power_acc + solar_energy_level;
                harvest_acc_cnt   <= harvest_acc_cnt + 4'd1;
            end
        end
    end

    assign harvest_low  = (solar_avg < SOLAR_LOW_THRESH);
    assign harvest_high = (solar_avg > SOLAR_HIGH_THRESH);
    assign batt_low     = (battery_avg < BATTERY_LOW_THRESH);
    assign batt_crit    = (battery_avg < BATTERY_CRIT_THRESH);

    assign battery_warning = batt_low;

    // -------------------------------------------------------------
    // Environmental derating (temperature / humidity)
    //    - temp_derate      : PV harvest is discounted at high temp
    //    - humidity_high    : flags likely-overcast/rain conditions
    // Both are registered (not combinational-only) so they land on
    // flops before fanning out to the prediction math, keeping the
    // critical path short and avoiding a wide comb cone off two
    // 12-bit sensor inputs.
    // -------------------------------------------------------------
    reg temp_derate;
    reg humidity_high;

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            temp_derate   <= 1'b0;
            humidity_high <= 1'b0;
        end else begin
            temp_derate   <= (temperature_sensor > TEMP_HIGH_THRESH);
            humidity_high <= (humidity_sensor    > HUMIDITY_HIGH_THRESH);
        end
    end

    // Effective solar average after environmental derating:
    //   - high temperature : -25% (>>2 subtraction)
    //   - high humidity    : -12.5% (>>3 subtraction)
    // The two penalties can stack (hot AND humid = worst case).
    wire [11:0] solar_avg_temp_adj;
    wire [11:0] solar_avg_effective;

    assign solar_avg_temp_adj  = temp_derate   ? (solar_avg          - (solar_avg          >> 2))
                                                : solar_avg;
    assign solar_avg_effective = humidity_high ? (solar_avg_temp_adj - (solar_avg_temp_adj >> 3))
                                                : solar_avg_temp_adj;

    // Combined 13-bit energy score = weighted (derated) solar + battery
    wire [12:0] energy_score;
    assign energy_score = {1'b0, solar_avg_effective} + {1'b0, battery_avg};

    // =====================================================================
    // 3. ENERGY PREDICTION ENGINE (FSM)
    //    States: LOW, MEDIUM, HIGH, CRITICAL (binary encoded)
    // =====================================================================
    localparam [1:0] PRED_LOW      = 2'b00;
    localparam [1:0] PRED_MEDIUM   = 2'b01;
    localparam [1:0] PRED_HIGH     = 2'b10;
    localparam [1:0] PRED_CRITICAL = 2'b11;

    reg [1:0] predict_state, predict_state_nxt;
    reg [7:0] prediction_score_reg;

    // Next-state combinational logic (no latches: full case coverage)
    always @(*) begin
        predict_state_nxt = predict_state;
        if (batt_crit) begin
            predict_state_nxt = PRED_CRITICAL;
        end else begin
            case (predict_state)
                PRED_LOW: begin
                    if (energy_score > SCORE_LOW_MAX)
                        predict_state_nxt = PRED_MEDIUM;
                    else
                        predict_state_nxt = PRED_LOW;
                end
                PRED_MEDIUM: begin
                    if (energy_score > SCORE_MED_MAX)
                        predict_state_nxt = PRED_HIGH;
                    else if (energy_score <= SCORE_LOW_MAX)
                        predict_state_nxt = PRED_LOW;
                    else
                        predict_state_nxt = PRED_MEDIUM;
                end
                PRED_HIGH: begin
                    if (energy_score > SCORE_HIGH_MAX)
                        predict_state_nxt = PRED_HIGH; // saturate
                    else if (energy_score <= SCORE_MED_MAX)
                        predict_state_nxt = PRED_MEDIUM;
                    else
                        predict_state_nxt = PRED_HIGH;
                end
                PRED_CRITICAL: begin
                    if (!batt_crit && energy_score > SCORE_LOW_MAX)
                        predict_state_nxt = PRED_MEDIUM;
                    else if (!batt_crit)
                        predict_state_nxt = PRED_LOW;
                    else
                        predict_state_nxt = PRED_CRITICAL;
                end
                default: predict_state_nxt = PRED_LOW;
            endcase
        end
    end

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync)
            predict_state <= PRED_LOW;
        else
            predict_state <= predict_state_nxt;
    end

    // Prediction score: clamp energy_score[12:5] to 8 bits
    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync)
            prediction_score_reg <= 8'd0;
        else
            prediction_score_reg <= energy_score[12:5];
    end

    assign energy_prediction = prediction_score_reg;

    // =====================================================================
    // 4. ADAPTIVE SCHEDULER
    //    Enable/disable CPU, radio, sensors according to prediction state
    // =====================================================================
    reg cpu_en_reg, radio_en_reg, sensor_en_reg, lpm_reg;

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            cpu_en_reg    <= 1'b1;
            radio_en_reg  <= 1'b0;
            sensor_en_reg <= 1'b1;
            lpm_reg       <= 1'b0;
        end else begin
            case (predict_state)
                PRED_HIGH: begin
                    cpu_en_reg    <= 1'b1;
                    radio_en_reg  <= 1'b1;
                    sensor_en_reg <= 1'b1;
                    lpm_reg       <= 1'b0;
                end
                PRED_MEDIUM: begin
                    cpu_en_reg    <= 1'b1;
                    radio_en_reg  <= 1'b1;
                    sensor_en_reg <= 1'b1;
                    lpm_reg       <= 1'b0;
                end
                PRED_LOW: begin
                    cpu_en_reg    <= 1'b1;
                    radio_en_reg  <= 1'b0;
                    sensor_en_reg <= 1'b1;
                    lpm_reg       <= 1'b1;
                end
                PRED_CRITICAL: begin
                    cpu_en_reg    <= motion_detect; // wake only on motion
                    radio_en_reg  <= 1'b0;
                    sensor_en_reg <= 1'b0;
                    lpm_reg       <= 1'b1;
                end
                default: begin
                    cpu_en_reg    <= 1'b1;
                    radio_en_reg  <= 1'b0;
                    sensor_en_reg <= 1'b1;
                    lpm_reg       <= 1'b0;
                end
            endcase
        end
    end

    assign cpu_enable    = cpu_en_reg;
    assign radio_enable  = radio_en_reg;
    assign sensor_enable = sensor_en_reg;
    assign low_power_mode = lpm_reg;

    // =====================================================================
    // 5. DUTY CYCLE CONTROLLER
    //    Sensing interval selection: FAST / NORMAL / SLOW / ULTRA_SLOW
    // =====================================================================
    localparam [1:0] DUTY_FAST       = 2'b00;
    localparam [1:0] DUTY_NORMAL     = 2'b01;
    localparam [1:0] DUTY_SLOW       = 2'b10;
    localparam [1:0] DUTY_ULTRA_SLOW = 2'b11;

    // Interval values in clock cycles @100MHz (kept small/representative
    // for a research-quality design; scaled by predicted energy state)
    localparam [23:0] INTERVAL_FAST       = 24'd100_000;   // 1 ms
    localparam [23:0] INTERVAL_NORMAL     = 24'd1_000_000; // 10 ms
    localparam [23:0] INTERVAL_SLOW       = 24'd5_000_000; // 50 ms
    localparam [23:0] INTERVAL_ULTRA_SLOW = 24'd16_700_000;// ~167 ms

    reg [1:0]  duty_state;
    reg [23:0] duty_counter;
    reg        sensor_tick;

    always @(*) begin
        case (predict_state)
            PRED_HIGH:     duty_state = DUTY_FAST;
            PRED_MEDIUM:   duty_state = DUTY_NORMAL;
            PRED_LOW:      duty_state = DUTY_SLOW;
            PRED_CRITICAL: duty_state = DUTY_ULTRA_SLOW;
            default:       duty_state = DUTY_NORMAL;
        endcase
    end

    reg [23:0] interval_sel;
    always @(*) begin
        case (duty_state)
            DUTY_FAST:       interval_sel = INTERVAL_FAST;
            DUTY_NORMAL:     interval_sel = INTERVAL_NORMAL;
            DUTY_SLOW:       interval_sel = INTERVAL_SLOW;
            DUTY_ULTRA_SLOW: interval_sel = INTERVAL_ULTRA_SLOW;
            default:         interval_sel = INTERVAL_NORMAL;
        endcase
    end

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            duty_counter <= 24'd0;
            sensor_tick  <= 1'b0;
        end else if (duty_counter >= interval_sel) begin
            duty_counter <= 24'd0;
            sensor_tick  <= 1'b1;
        end else begin
            duty_counter <= duty_counter + 24'd1;
            sensor_tick  <= 1'b0;
        end
    end

    // =====================================================================
    // 6. POWER MANAGER FSM
    //    States: ACTIVE, RECOVERY, SLEEP, DEEP_SLEEP (binary encoded)
    // =====================================================================
    localparam [1:0] PWR_ACTIVE     = 2'b00;
    localparam [1:0] PWR_RECOVERY   = 2'b01;
    localparam [1:0] PWR_SLEEP      = 2'b10;
    localparam [1:0] PWR_DEEP_SLEEP = 2'b11;

    reg [1:0] power_state, power_state_nxt;

    always @(*) begin
        power_state_nxt = power_state;
        case (power_state)
            PWR_ACTIVE: begin
                if (batt_crit)
                    power_state_nxt = PWR_DEEP_SLEEP;
                else if (predict_state == PRED_LOW)
                    power_state_nxt = PWR_SLEEP;
                else
                    power_state_nxt = PWR_ACTIVE;
            end
            PWR_SLEEP: begin
                if (batt_crit)
                    power_state_nxt = PWR_DEEP_SLEEP;
                else if (motion_detect || predict_state == PRED_HIGH)
                    power_state_nxt = PWR_RECOVERY;
                else
                    power_state_nxt = PWR_SLEEP;
            end
            PWR_DEEP_SLEEP: begin
                if (motion_detect && !batt_crit)
                    power_state_nxt = PWR_RECOVERY;
                else if (!batt_crit && predict_state != PRED_CRITICAL)
                    power_state_nxt = PWR_RECOVERY;
                else
                    power_state_nxt = PWR_DEEP_SLEEP;
            end
            PWR_RECOVERY: begin
                if (batt_crit)
                    power_state_nxt = PWR_DEEP_SLEEP;
                else
                    power_state_nxt = PWR_ACTIVE;
            end
            default: power_state_nxt = PWR_ACTIVE;
        endcase
    end

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync)
            power_state <= PWR_ACTIVE;
        else
            power_state <= power_state_nxt;
    end

    assign system_active = (power_state == PWR_ACTIVE) || (power_state == PWR_RECOVERY);
    assign sleep_mode     = (power_state == PWR_SLEEP) || (power_state == PWR_DEEP_SLEEP);

    // Wakeup detection pulse (SLEEP/DEEP_SLEEP -> RECOVERY transition)
    wire wakeup_event;
    assign wakeup_event = ((power_state == PWR_SLEEP) || (power_state == PWR_DEEP_SLEEP))
                          && (power_state_nxt == PWR_RECOVERY);
    // Sleep-entry pulse (ACTIVE -> SLEEP or any -> DEEP_SLEEP)
    wire sleep_event;
    assign sleep_event = (power_state != PWR_SLEEP) && (power_state_nxt == PWR_SLEEP);
    wire deep_sleep_event;
    assign deep_sleep_event = (power_state != PWR_DEEP_SLEEP) && (power_state_nxt == PWR_DEEP_SLEEP);

    // =====================================================================
    // 7. TIMER BLOCK
    //    - Free-running 32-bit timer
    //    - Programmable watchdog
    //    - Periodic interrupt generator
    // =====================================================================
    localparam [31:0] WATCHDOG_LIMIT   = 32'd200_000_000; // 2s @100MHz
    localparam [23:0] PERIODIC_LIMIT   = 24'd10_000_000;  // 100ms periodic

    reg [31:0] free_timer;
    reg [31:0] watchdog_cnt;
    reg        watchdog_kick;      // pulses on any system activity
    reg        watchdog_expired;
    reg [23:0] periodic_cnt;
    reg        periodic_pulse;

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync)
            free_timer <= 32'd0;
        else
            free_timer <= free_timer + 32'd1;
    end

    // Watchdog: kicked by sensor_tick (proof of forward progress)
    always @(posedge clk) begin
        watchdog_kick <= sensor_tick;
    end

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            watchdog_cnt     <= 32'd0;
            watchdog_expired <= 1'b0;
        end else if (watchdog_kick) begin
            watchdog_cnt     <= 32'd0;
            watchdog_expired <= 1'b0;
        end else if (watchdog_cnt >= WATCHDOG_LIMIT) begin
            watchdog_cnt     <= watchdog_cnt;
            watchdog_expired <= 1'b1;
        end else begin
            watchdog_cnt     <= watchdog_cnt + 32'd1;
            watchdog_expired <= 1'b0;
        end
    end

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            periodic_cnt   <= 24'd0;
            periodic_pulse <= 1'b0;
        end else if (periodic_cnt >= PERIODIC_LIMIT) begin
            periodic_cnt   <= 24'd0;
            periodic_pulse <= 1'b1;
        end else begin
            periodic_cnt   <= periodic_cnt + 24'd1;
            periodic_pulse <= 1'b0;
        end
    end

    // =====================================================================
    // 8. PERFORMANCE COUNTERS (16-bit saturating)
    // =====================================================================
    reg [15:0] cnt_wakeups;
    reg [15:0] cnt_sleep_cycles;
    reg [15:0] cnt_harvest_events;
    reg [15:0] cnt_sensor_events;
    reg [15:0] cnt_uart_packets;

    wire uart_tx_done_pulse; // defined in UART section below

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            cnt_wakeups        <= 16'd0;
            cnt_sleep_cycles   <= 16'd0;
            cnt_harvest_events <= 16'd0;
            cnt_sensor_events  <= 16'd0;
            cnt_uart_packets   <= 16'd0;
        end else begin
            if (wakeup_event && cnt_wakeups != 16'hFFFF)
                cnt_wakeups <= cnt_wakeups + 16'd1;

            if (sleep_mode && cnt_sleep_cycles != 16'hFFFF)
                cnt_sleep_cycles <= cnt_sleep_cycles + 16'd1;

            if (harvest_valid && cnt_harvest_events != 16'hFFFF)
                cnt_harvest_events <= cnt_harvest_events + 16'd1;

            if (sensor_tick && cnt_sensor_events != 16'hFFFF)
                cnt_sensor_events <= cnt_sensor_events + 16'd1;

            if (uart_tx_done_pulse && cnt_uart_packets != 16'hFFFF)
                cnt_uart_packets <= cnt_uart_packets + 16'd1;
        end
    end

    // =====================================================================
    // 9. REGISTER BANK (memory mapped, internal)
    //    16 x 8-bit registers exposed for debug read-back.
    //    Addr map:
    //      0  STATUS      {sys_active,sleep,lpm,batt_warn,predict[1:0],pwr[1:0]}
    //      1  BATTERY_PCT
    //      2  SOLAR_AVG[11:4]
    //      3  SOLAR_AVG[3:0],4'b0
    //      4  PREDICTION_SCORE
    //      5  ENERGY_SCORE[12:5]
    //      6  ENERGY_SCORE[4:0],3'b0
    //      7  WEATHER_STATUS {temp_derate,humidity_high,harvest_valid,
    //                          motion_detect,4'b0000}
    //      8  TIMER[31:24]
    //      9  TIMER[23:16]
    //      10 WAKEUP_COUNT[7:0]
    //      11 SLEEP_COUNT[7:0]
    //      12 HARVEST_EVENT_COUNT[7:0]
    //      13 SENSOR_EVENT_COUNT[7:0]
    //      14 UART_PACKET_COUNT[7:0]
    //      15 DEBUG_SEL (loopback of current select)
    // =====================================================================
    reg [3:0] debug_sel;

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync)
            debug_sel <= 4'd0;
        else if (periodic_pulse)
            debug_sel <= debug_sel + 4'd1; // round-robin scan for debug export
    end

    reg [7:0] reg_rdata;
    always @(*) begin
        case (debug_sel)
            4'd0:  reg_rdata = {system_active, sleep_mode, lpm_reg, battery_warning,
                                 predict_state, power_state};
            4'd1:  reg_rdata = battery_pct;
            4'd2:  reg_rdata = solar_avg[11:4];
            4'd3:  reg_rdata = {solar_avg[3:0], 4'b0000};
            4'd4:  reg_rdata = prediction_score_reg;
            4'd5:  reg_rdata = energy_score[12:5];
            4'd6:  reg_rdata = {energy_score[4:0], 3'b000};
            4'd7:  reg_rdata = {temp_derate, humidity_high, harvest_valid,
                                 motion_detect, 4'b0000}; // WEATHER_STATUS
            4'd8:  reg_rdata = free_timer[31:24];
            4'd9:  reg_rdata = free_timer[23:16];
            4'd10: reg_rdata = cnt_wakeups[7:0];
            4'd11: reg_rdata = cnt_sleep_cycles[7:0];
            4'd12: reg_rdata = cnt_harvest_events[7:0];
            4'd13: reg_rdata = cnt_sensor_events[7:0];
            4'd14: reg_rdata = cnt_uart_packets[7:0];
            4'd15: reg_rdata = {4'b0000, debug_sel};
            default: reg_rdata = 8'h00;
        endcase
    end

    // =====================================================================
    // 10. UART DEBUG TRANSMITTER (115200-8N1, TX only)
    //     Transmits the STATUS register (reg addr 0) every periodic_pulse.
    // =====================================================================
    localparam [2:0] UART_IDLE  = 3'b000;
    localparam [2:0] UART_START = 3'b001;
    localparam [2:0] UART_DATA  = 3'b010;
    localparam [2:0] UART_STOP  = 3'b011;

    reg [2:0]  uart_state;
    reg [15:0] uart_baud_cnt;
    reg [2:0]  uart_bit_idx;
    reg [7:0]  uart_shift;
    reg        uart_tx_reg;
    reg        uart_tx_done;

    wire uart_baud_tick;
    assign uart_baud_tick = (uart_baud_cnt == (UART_DIV - 1));

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync)
            uart_baud_cnt <= 16'd0;
        else if (uart_state == UART_IDLE)
            uart_baud_cnt <= 16'd0;
        else if (uart_baud_tick)
            uart_baud_cnt <= 16'd0;
        else
            uart_baud_cnt <= uart_baud_cnt + 16'd1;
    end

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            uart_state   <= UART_IDLE;
            uart_bit_idx <= 3'd0;
            uart_shift   <= 8'd0;
            uart_tx_reg  <= 1'b1; // idle high
            uart_tx_done <= 1'b0;
        end else begin
            uart_tx_done <= 1'b0;
            case (uart_state)
                UART_IDLE: begin
                    uart_tx_reg <= 1'b1;
                    if (periodic_pulse || host_request) begin
                        uart_shift <= reg_rdata; // snapshot currently-selected register
                        uart_state <= UART_START;
                    end
                end
                UART_START: begin
                    uart_tx_reg <= 1'b0; // start bit
                    if (uart_baud_tick) begin
                        uart_bit_idx <= 3'd0;
                        uart_state   <= UART_DATA;
                    end
                end
                UART_DATA: begin
                    uart_tx_reg <= uart_shift[uart_bit_idx];
                    if (uart_baud_tick) begin
                        if (uart_bit_idx == 3'd7) begin
                            uart_state <= UART_STOP;
                        end else begin
                            uart_bit_idx <= uart_bit_idx + 3'd1;
                        end
                    end
                end
                UART_STOP: begin
                    uart_tx_reg <= 1'b1; // stop bit
                    if (uart_baud_tick) begin
                        uart_state   <= UART_IDLE;
                        uart_tx_done <= 1'b1;
                    end
                end
                default: uart_state <= UART_IDLE;
            endcase
        end
    end

    assign uart_tx = uart_tx_reg;
    assign uart_tx_done_pulse = uart_tx_done;

    // -------------------------------------------------------------
    // uart_rx host-request detector
    //    Full UART reception is not required by the spec ("No
    //    receiver required unless needed"), but a bare tie-off left
    //    the pin logically dead. Instead, uart_rx is synchronized and
    //    its falling edge (a UART start bit, line idles high) is used
    //    as an on-demand trigger: a host can force an immediate debug
    //    status dump instead of waiting for the next periodic_pulse.
    //    This gives the pin a real function without implementing a
    //    full 8N1 receiver/shift-register.
    // -------------------------------------------------------------
    reg [1:0] uart_rx_sync;
    reg       uart_rx_prev;
    reg       host_request;

    always @(posedge clk or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            uart_rx_sync <= 2'b11; // idle-high default
            uart_rx_prev <= 1'b1;
            host_request <= 1'b0;
        end else begin
            uart_rx_sync <= {uart_rx_sync[0], uart_rx};
            uart_rx_prev <= uart_rx_sync[1];
            // Falling-edge pulse: idle(1) -> start bit(0)
            host_request <= uart_rx_prev & ~uart_rx_sync[1];
        end
    end

    // =====================================================================
    // 11. DEBUG LOGIC - 32-bit debug bus export
    //     Note: harvest_valid / motion_detect are not repeated here to
    //     make room for the environmental derate flags; both remain
    //     directly observable via register 7 (WEATHER_STATUS) and
    //     indirectly via the harvest/sensor event counters.
    // =====================================================================
    assign debug_bus = {
        power_state,            // [31:30]
        predict_state,          // [29:28]
        duty_state,             // [27:26]
        battery_warning,        // [25]
        sleep_mode,             // [24]
        low_power_mode,         // [23]
        system_active,          // [22]
        temp_derate,            // [21]
        humidity_high,          // [20]
        prediction_score_reg,   // [19:12]
        reg_rdata,              // [11:4]
        debug_sel               // [3:0]
    };

endmodule

