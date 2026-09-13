# IHP SG13G2 Density and Metal Fill DRC Resolution Report

## 1. Objective

The objective of this work was to identify and resolve the **Active-density, global metal-density, and local metal-fill-related DRC violations** in the IHP SG13G2 physical design generated using the OpenROAD flow.

The main objectives were:

- Identify the cause of the density and metal-fill DRC violations.
- Determine whether the violations were caused by the physical design, floorplan, or missing density fill.
- Enable the appropriate OpenROAD density-fill mechanism.
- Analyze the IHP SG13G2 minimal DRC density rules.
- Adjust the design floorplan to satisfy the local density-check requirement.
- Resolve the PDN constraint introduced by the revised floorplan.
- Regenerate the physical design and final GDS.
- Verify the final GDS using the IHP SG13G2 minimal KLayout DRC deck.
- Achieve zero violations for all density- and fill-related rules.
- Keep the foundry DRC rule deck unchanged.

---

## 2. Design and Verification Environment

The physical design was generated using:

- **Technology:** IHP SG13G2
- **Technology node:** 130 nm
- **Physical design tool:** OpenROAD
- **DRC tool:** KLayout
- **DRC deck:** `sg13g2_minimal.lydrc`
- **Final layout:** `6_final.gds`
- **Final DRC report:** `6_final_minimal.lyrdb`

The DRC was executed using:

```bash
klayout -b \
-r /home/abmtafsir/OpenROAD-flow-scripts/flow/platforms/ihp-sg13g2/drc/sg13g2_minimal.lydrc \
-rd in_gds=6_final.gds \
-rd report_file=6_final_minimal.lyrdb
```

To open the report in klayout

```
klayout 6_final.gds -m 6_final_minimal.lyrdb
```

---

# 3. Initial DRC Condition

The initial KLayout minimal DRC reported seven density/fill-related violations.

| DRC Rule | Requirement | Initial Errors |
|---|---|---:|
| `AFil.g` | Minimum global Active density = 35% | 1 |
| `M1.j` | Minimum global Metal1 density = 35% | 1 |
| `M2.j` | Minimum global Metal2 density = 35% | 1 |
| `M3.j` | Minimum global Metal3 density = 35% | 1 |
| `M4.j` | Minimum global Metal4 density = 35% | 1 |
| `M5.j` | Minimum global Metal5 density = 35% | 0 |
| `M2Fil.h` | Minimum M2 + M2 filler density = 25% in an 800 × 800 µm² area | 1 |
| `M3Fil.h` | Minimum M3 + M3 filler density = 25% in an 800 × 800 µm² area | 1 |

Therefore, the total number of density/fill-related violations was:

```text
7
```

The pin-related rules were analyzed separately and are not included in this density/fill report.

---

# 4. Analysis of the IHP SG13G2 Density Rules

The IHP SG13G2 minimal DRC deck was inspected to determine the exact requirements and the geometry used in the density calculation.

## 4.1 Active Density Rule

The DRC deck defines the Active density as:

```text
Act_density = Activ.ext_or(Activ_filler)
```

The minimum global Active density requirement is:

```text
AFil.g
Minimum global Active density = 35%
```

Therefore, Active filler geometry contributes to the Active-density calculation.

---

## 4.2 Global Metal Density Rules

The DRC deck defines the metal-density regions as:

```text
M1_density = Metal1.ext_or(Metal1_filler).ext_not(Metal1_slit)
M2_density = Metal2.ext_or(Metal2_filler).ext_not(Metal2_slit)
M3_density = Metal3.ext_or(Metal3_filler).ext_not(Metal3_slit)
M4_density = Metal4.ext_or(Metal4_filler).ext_not(Metal4_slit)
M5_density = Metal5.ext_or(Metal5_filler).ext_not(Metal5_slit)
```

The minimum global density requirements are:

```text
Metal1 ≥ 35%
Metal2 ≥ 35%
Metal3 ≥ 35%
Metal4 ≥ 35%
Metal5 ≥ 35%
```

This analysis confirmed that metal filler contributes to the global metal-density calculation.

---

## 4.3 Local Metal Fill Density Rules

The local fill-density checks use an:

```text
800 µm × 800 µm
```

window.

The relevant minimum requirements are:

```text
M1 + M1 filler ≥ 25%
M2 + M2 filler ≥ 25%
M3 + M3 filler ≥ 25%
M4 + M4 filler ≥ 25%
M5 + M5 filler ≥ 25%
```

The initial local-density violations were:

```text
M2Fil.h
M3Fil.h
```

---

# 5. Root Causes of the Density and Fill Violations

## 5.1 Density Fill Was Not Initially Enabled

The OpenROAD platform contained an SG13G2 metal-fill configuration:

```text
flow/platforms/ihp-sg13g2/fill.json
```

However, the design configuration did not initially enable the density-fill stage.

Consequently, the generated layout did not contain sufficient floating metal to satisfy the minimum metal-density requirements on all required layers.

---

## 5.2 Insufficient Global Physical Density

The original layout had insufficient geometry for several minimum-density requirements.

The affected layers were:

```text
Active
Metal1
Metal2
Metal3
Metal4
```

Metal5 already satisfied its global minimum-density requirement.

The DRC deck includes filler geometry in the density calculation, making legal density filler an appropriate method for increasing the coverage.

---

## 5.3 Original Die Size Was Smaller Than the Local Density Window

The original final DEF contained a die approximately:

```text
309.055 µm × 309.055 µm
```

The IHP local density rules for `M2Fil.h` and `M3Fil.h` check:

```text
800 µm × 800 µm
```

Therefore, there was a significant mismatch between the original die size and the local density-check window.

This was a major factor in the local Metal2 and Metal3 fill-density violations.

---

## 5.4 Original Floorplan Had Insufficient Area for the 800 × 800 µm² Check

The original automatically generated floorplan was approximately:

```text
309.055 × 309.055 µm²
```

while the IHP local density checks use an 800 × 800 µm² region.

To satisfy the strict minimal DRC, the physical floorplan was therefore changed to use an 800 × 800 µm² die.

---

# 6. Solution Method

## 6.1 Enable OpenROAD Density Fill

The first design-level change was to enable the density-fill stage:

```make
export USE_FILL = 1
```

This allowed OpenROAD to generate metal filler structures using the SG13G2 fill configuration.

The SG13G2 fill configuration contains fill definitions for:

```text
Metal1
Metal2
Metal3
Metal4
Metal5
TopMetal1
TopMetal2
```

No change was made to the foundry DRC rule deck.

---

# 7. Floorplan Modification

The original die was approximately:

```text
309.055 × 309.055 µm²
```

The die was changed to:

```text
800 × 800 µm²
```

An initial explicit floorplan was:

```make
export DIE_AREA  = 0 0 800 800
export CORE_AREA = 10 10 790 790
```

This configuration successfully changed the die size but caused a PDN ring placement error.

---

# 8. PDN Ring Issue After Floorplan Modification

The initial 800 × 800 µm² floorplan produced the following PDN error:

```text
[ERROR PDN-0351] PDN rings do not fit inside the die area by
6.42 um in X and 5.16 um in Y.
```

The problem was insufficient space between the die boundary and the core for the configured PDN rings.

The core area was therefore changed from:

```text
10 10 790 790
```

to:

```text
20 20 780 780
```

The resulting floorplan provides:

```text
Die  = 800 × 800 µm²
Core = 760 × 760 µm²
```

with 20 µm spacing between the core and die boundary.

This allowed the PDN rings to fit inside the die.

---

# 9. Floorplan Initialization Issue

An attempt to use:

```make
export CORE_UTILIZATION = 40
```

together with explicit:

```make
export DIE_AREA  = 0 0 800 800
export CORE_AREA = 20 20 780 780
```

produced:

```text
Error: Floorplan initialization methods are mutually exclusive,
pick one.
```

The reason was that OpenROAD does not allow explicit die/core dimensions and utilization-based floorplan initialization to be used simultaneously.

Therefore, `CORE_UTILIZATION` was removed while retaining the explicit die and core dimensions.

The final relevant configuration became:

```make
export DIE_AREA       = 0 0 800 800
export CORE_AREA      = 20 20 780 780
export PLACE_DENSITY  = 0.55
export USE_FILL       = 1
```

---

# 10. Physical Design Regeneration

The complete OpenROAD physical-design flow was regenerated using the updated configuration.

The flow successfully generated the density-fill stage and final layout files, including:

```text
6_1_fill.odb
6_1_fill.v
6_1_merged.gds
6_final.def
6_final.gds
6_final.odb
```

The final GDS was then used for KLayout DRC verification.

---

# 11. Final DRC Verification

The final GDS was verified using the IHP SG13G2 minimal DRC deck.

The final density/fill results were:

| DRC Rule | Final Errors | Status |
|---|---:|---|
| `AFil.g` | 0 | PASS |
| `M1.j` | 0 | PASS |
| `M2.j` | 0 | PASS |
| `M3.j` | 0 | PASS |
| `M4.j` | 0 | PASS |
| `M5.j` | 0 | PASS |
| `M1Fil.h` | 0 | PASS |
| `M2Fil.h` | 0 | PASS |
| `M3Fil.h` | 0 | PASS |
| `M4Fil.h` | 0 | PASS |
| `M5Fil.h` | 0 | PASS |

---

# 12. Before and After Comparison

## 12.1 Initial Condition

```text
AFil.g      = 1
M1.j        = 1
M2.j        = 1
M3.j        = 1
M4.j        = 1
M5.j        = 0
M2Fil.h     = 1
M3Fil.h     = 1
```

Total density/fill violations:

```text
7
```

---

## 12.2 Final Condition

```text
AFil.g      = 0
M1.j        = 0
M2.j        = 0
M3.j        = 0
M4.j        = 0
M5.j        = 0

M1Fil.h     = 0
M2Fil.h     = 0
M3Fil.h     = 0
M4Fil.h     = 0
M5Fil.h     = 0
```

Total density/fill violations:

```text
0
```

---

# 13. DRC Improvement

The density/fill DRC status improved from:

```text
7 violations
```

to:

```text
0 violations
```

Therefore:

```text
Density/fill DRC improvement = 100%
```

All minimum global and local density requirements included in the analyzed rules are now satisfied.

---

# 14. Final Design Configuration

The final design-level configuration used to resolve the density/fill violations is:

```make
export DIE_AREA       = 0 0 800 800
export CORE_AREA      = 20 20 780 780
export PLACE_DENSITY  = 0.55
export USE_FILL       = 1
```

The following was intentionally not modified:

```text
flow/platforms/ihp-sg13g2/drc/sg13g2_minimal.lydrc
```

The IHP SG13G2 foundry DRC rules and density thresholds were therefore preserved.

---

# 15. Final Outcome

The final KLayout DRC shows that all density and fill-related checks are clean.

### Global Density

```text
Active density       → PASS
Metal1 density       → PASS
Metal2 density       → PASS
Metal3 density       → PASS
Metal4 density       → PASS
Metal5 density       → PASS
```

### Local Metal Fill Density

```text
Metal1 fill density  → PASS
Metal2 fill density  → PASS
Metal3 fill density  → PASS
Metal4 fill density  → PASS
Metal5 fill density  → PASS
```

Final result:

```text
Initial density/fill violations = 7
Final density/fill violations   = 0
```

---

# 16. Conclusion

The density and metal-fill DRC violations in the IHP SG13G2 design were resolved through physical-design configuration changes rather than modification of the foundry DRC rules.

The main causes were:

1. Density fill was not initially enabled.
2. Global Active and M1–M4 metal densities were below the required minimum values.
3. The original approximately 309.055 × 309.055 µm² die was smaller than the 800 × 800 µm² local density-check window.
4. The initial expanded floorplan required additional core-to-die spacing to accommodate the PDN rings.

The applied solution consisted of:

1. Enabling OpenROAD density fill with:
   ```make
   USE_FILL = 1
   ```

2. Changing the die size to:
   ```text
   800 × 800 µm²
   ```

3. Setting the core area to:
   ```text
   20 20 780 780
   ```

4. Keeping:
   ```make
   PLACE_DENSITY = 0.55
   ```

5. Removing the conflicting utilization-based floorplan initialization.

6. Regenerating the complete physical design.

7. Re-running the IHP SG13G2 minimal DRC on the final GDS.

The final verification confirms:

> **All Active-density, global metal-density, and local metal-fill density violations were successfully eliminated.**

The density/fill portion of the IHP SG13G2 minimal DRC is therefore:

```text
CLEAN — 0 VIOLATIONS
```

The remaining DRC violations in the final report are `Pin.f.M2` and `Pin.f.M3`, which are pin-related checks and are outside the scope of this density and metal-fill report.
