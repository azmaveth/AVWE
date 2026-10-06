# AVWE heat, fire and smoke: specification

> Synthesized by a design panel (three proposals, three judges) on 2026-10-05.
> The body below is the panel's spec. This first section is the implementation
> plan the orchestrator added; where they disagree, this section wins.

## Implementation plan

Work is split into three slices. A and B run in parallel in separate
worktrees; C integrates after they are merged.

**Slice A (heat):** `Avwe.Systems.Weather` (§2), `Daylight.mean_light/2` (§3),
`Avwe.Systems.Heat` (§4), the River changes (§5), `Worldgen.add_climate` and
the `climate:` config key (§8), the heat/weather/river tests (§13 items 1-16,
with the changes below). Owns: weather.ex, heat.ex, daylight.ex, river.ex and
their tests. Heat reads hearth components by the contract in §6.1 but Slice A
builds its own hand-made hearth entities (with a precomputed `last_step`) in
tests; it must not implement Fire.

**Slice B (fire and smoke):** `Avwe.Systems.Fire` (§6) including the verbs in
`Avwe.Actions` and `Avwe.Intent`, `Avwe.Systems.Smoke` (§7), telnet commands
(§6.4, in `Avwe.Telnet.Command` and `Connection`), `Worldgen.add_hearths` and
standing miracles plus the `hearths:` config key and the Last Coal entry (§8),
the fire/smoke tests (§13 items 17-23). Owns: fire.ex, smoke.ex, actions.ex,
intent.ex, telnet/*, and their tests. Slice B must not implement Heat; it may
read `env.wind` with the §2.1 default when absent.

**Shared files** (both slices touch them; keep edits minimal and additive so
the merge is trivial): `lib/avwe/worldgen.ex` (A adds `add_climate/2`, B adds
`add_hearths/2` and the standing-miracle branch of `add_miracles/2`),
`config/config.exs` (A adds `climate:`, B adds `hearths:` and the Last Coal
miracle), `test/support/ember.ex` (each passes its own keys through),
`lib/avwe.ex` (`@default_systems`: each slice adds only its own systems in the
§1 order; the orchestrator reconciles).

**Slice C (integration, after merge):** `Percept.modality :smell`,
`Perception`, `Prose`, the `look` additions and affordances (§9), the e2e
tests (§13: fire_test.exs, session/river/perception additions), and the
integrated conservation property with a `kindle` (§13 item 4's `kindle?`
variable moves here). Slices A and B must not edit perception.ex, prose.ex
or percept.ex.

Changes to the panel's spec:
- §13 item 4: the `kindle?` variable is dropped from Slice A's property and
  returns in Slice C's integrated version. Slice A's property instead places a
  hand-built burning hearth (per §6.1, with a fixed `last_step`) at the town.
- §13 item 16 (cost): tag it `:perf`, exclude `:perf` by default in
  `test/test_helper.exs`, and assert mean < 10 ms when run with
  `--include perf`.
- §1 order: the orchestrator sets `@default_systems` after the merge.
- Prose strings in §9 are exact; Slice C implements them verbatim so the e2e
  tests can quote them.

Everything else stands as written.

## As built: errata

Where the code deliberately differs from the body below, the code and its
moduledocs are right. The differences, with their reasons:

- **Steam threshold (§4.2, §4.4):** `@steam_dc` is 12 K, not 8 K, and there
  is one rule everywhere: a reach steams when its bank mean is at least 12 K
  above the end-of-step air, with no light condition; a body's `look` uses
  the flag of the reach beside it, and so does the river prose. With the
  model's 40 °C spring the water by the town is about 37.7 °C (not the ~34 °C
  the reference day assumed) and the bank silt at d = 3 runs 29 to 32 °C, so
  with 8 K the banks steamed from mid-afternoon in full sun; with 12 K the
  first reach steams about 16:40 and the last about 17:50, and they clear
  between 06:50 and 08:00. The banks are `:hot` (15 K over the air) through
  the night while the river runs.
- **River at long steps (§5):** the chain of reaches is sub-stepped at 60 s
  inside the river system (a 300 s sub-step left a 5.6 % storage error), so
  hour and day steps drain the river at the right speed; each reach is still
  solved exactly. The river's temperature is the exact solution of the
  well-mixed reach, not the spec's mix-then-cool.
- **Smoke (§7):** `@g_min` is 0.25 mg (0.01 g culled minute-step puffs that
  hour steps kept), and each hearth emits up to four parcels per step along
  the drift line (`n = min(4, ceil(dt / 15))`), each with the closed form of
  its own sub-interval, so a body 100 m downwind does not lose the smell
  between minutes; the puff bound is therefore 4 × the spec's (at most 304
  per hearth at 60 s steps). A body within one cell of a burning hearth
  smells at least `:clear`. Puffs are bounded by the terrain's height as
  well as its width.
- **Heat budget (§10):** `last_step` has an `activated_mj` line for cells
  inserted during the step, and the delta identity includes it;
  `Heat.activate/3` returns `{field, joules}`.
- **Fire (§6.2, §6.4):** dousing an unquenchable hearth is outcome
  `:failure` with reason `:unquenchable` (you try, and it does not go out),
  not `:blocked`; standing miracles never smoke and the `smoke` key is gone.
  Telnet accepts a hearth name after `kindle`, `light`, `douse` and
  `put out`, resolved against the hearths within reach.
- **Perception (§9):** `look` carries `hearths`, every hearth within 2 cells
  (the nearest is also `hearth`), and `warmth.sources`, every burning source
  felt; `fires` excludes hearths within 2 cells, which are listed as hearths.
  `smoke` is present whenever the smoke field exists, even without terrain.
  "The fire burns low." and "The fire goes out." name the hearth when the
  observer is not at it.
- **Weather:** `Worldgen` validates the wind (`from` a compass direction,
  `m_s` at least 0) at build time.
- **Changed in M1** (`docs/m1-spec.md`, errata): smoke smelled at a fire
  names that fire instead of the wind (`"Woodsmoke rises from #{name}
  beside you."`, `"The smoke from #{name} beside you is thick."`), in the
  percept and the look; and a kindle or douse whose target is no hearth's
  id says `"You find no hearth by that name within reach."`.

---

Repo `/Users/azmaveth/code/avwe`, branch `m0-scaffold`. This is the synthesis: Proposal 2 (favoured by two of three judges) is the base; Proposal 1's energy-relative storage, compensated sums, closed-form puff emission and constant-forcing exactness test are grafted in; Proposal 3's split budget lines, `out_at`, `Heat.sources/1` and no-terrain clause are grafted in. Section 0 lists every judge objection and what was done with it.

New modules: `lib/avwe/systems/weather.ex`, `lib/avwe/systems/heat.ex`, `lib/avwe/systems/fire.ex`, `lib/avwe/systems/smoke.ex`. Changed: `daylight.ex`, `river.ex`, `actions.ex`, `intent.ex`, `percept.ex`, `perception.ex`, `prose.ex`, `worldgen.ex`, `telnet/command.ex`, `telnet/connection.ex`, `lib/avwe.ex` (default systems), `test/support/ember.ex`, `config/config.exs`.

Units: temperatures °C, energy J inside the systems and MJ in budget records, smoke in grams, distances in cells unless suffixed `_m`, time in world seconds. Cell area `A = 100 m²`.

## 0. Judge objections: accepted, rejected

| Objection | Decision |
|---|---|
| P2 storage sums in absolute °C make the 1e-6 MJ check ride on summation order (all three judges) | Accepted. Energy is stored per cell in J relative to `t_ref_c = 15.0`; every budget line and both storage totals use Neumaier compensated summation; the cell update is `E' = E + ΣQ` so storage change equals the lines by construction (§4.4). |
| P2 smoke bookkeeping contradicts itself (`a_prev` undefined, partial-interval deferral vs per-step `emitted == burned`) | Accepted. The 120 s ladder is gone. One puff per hearth per step with the closed-form survived mass and decay-weighted mean age (§7.2). `emitted_g == burned_kg * 10` holds every step. |
| P2 active set is fixed at prepare; a hearth created later has no cell | Accepted. Cells activate on demand (§4.3): a source at an inactive cell activates it, initialised from its material's background energy, which is exactly what that cell would hold. Nothing is dropped from the budget. |
| P2 felt warmth is zero one cell from a hearth | Accepted. Irradiance is the radiant half into a hemisphere, `0.5·P/(2π·d²)`, with a `:faint` band at 2 W/m², so a 5 kW hearth is `:faint` at 10 and 14 m and `:hot` in its own cell (§6.5). |
| P2 hourly `Tick.rng` wind: reseeds per puff per hour, and the "force wind from the north" test is hand-waved | Accepted by removal. Wind is constant per region, set from config (`env.wind`). A varying wind belongs to a later weather system and only `Smoke.drift_cells/3` would change. Tests set the wind in overrides. No randomness anywhere in these four systems. |
| P2 `vented_j` (70 % of hearth heat) is in no budget line; `miracles_mj == 0.3·800·dt` not the declared 800 W | Accepted as a declaration, not a change: the heat budget is the ground store's. `hearth.last_step` records `heat_j == ground_j + vented_j` exactly; `vented_j` goes to the prescribed air reservoir, which stores nothing. The Last Coal declares `heat_w: 800.0` and the ground line books `0.3·800·dt`; both numbers are asserted (§10). |
| P2's piecewise air curve is more error-prone than a cosine | Rejected. A cosine puts the 19:00 air at 24–27 °C and the banks never steam at dusk (Judge 1 and 3 showed this for Proposal 3). The piecewise curve is continuous, has a closed-form integral, and reference values and a trapezoid test pin it (§2, §10). |
| P2's "silt cell 3 from the channel near the town" is clay | Accepted. Test cells are chosen by `Terrain.ground/2`, not by distance alone (§10). |
| `test/e2e/river_test.exs` naming | It exists (`test/e2e/river_test.exs` and `test/avwe/systems/river_test.exs` both); both get updates. |
| Graft from P3: derived closed-form plume for dt ≥ 1 h (Judge 2) | Rejected. Two smoke representations and a mode switch for a plume nobody sniffs in history mode. The per-step closed form already makes mass exact at any dt; at hour steps each hearth leaves one puff per step at the plume's centre of mass, which is the right first-order answer and bounded. |
| Graft from P2: `k_riv` falling with bank distance | Kept (it is P2's). |
| Graft: `storage_before` independently recomputed in the test; split `sky_in/out`, `river_in/out`; `Heat.sources/1`; `out_at`; `:fire_low`; `:too_far`; `target: nil` = nearest hearth; telnet `light the fire` / `put out the fire`; seed-independence determinism test; no-terrain clause; 1.2 s `Terrain.ground` scan avoided | All accepted. |

## 1. System order

`Avwe.@default_systems` (in `lib/avwe.ex`) and `Avwe.Test.Ember.@systems` become:

```elixir
[Avwe.Systems.Daylight, Avwe.Systems.Miracles, Avwe.Systems.Weather, Avwe.Systems.River,
 Avwe.Systems.Fire, Avwe.Systems.Heat, Avwe.Systems.Movement, Avwe.Systems.Waiting,
 Avwe.Systems.Discovery, Avwe.Systems.Smoke]
```

Weather before River (water cools toward the real air). River before Heat (the ground sees this step's reach state, which is the *end-of-step* state because River has already run). Fire before Heat (this step's burn is this step's ground heat). Smoke last so smell is evaluated at bodies' end-of-step positions. `Region.prepare/1` runs `prepare/1` in the same order, so `Heat.prepare` sees a settled river. This deviates from DESIGN.md 6.3's "movement → fire → heat → water → weather" because water and weather must prepare before heat and never read the field; the design doc gets a one-line note.

## 2. `Avwe.Systems.Weather`

Owns the air and sky temperatures and publishes the wind. No randomness.

### 2.1 env

```elixir
env.air_c :: float     # instantaneous air at the END of the step (perception)
env.sky_c :: float     # air_c - 10.0
env.wind  :: %{from: "south-west", m_s: 2.0}   # set by Worldgen from config; constant
```

### 2.2 Air temperature

Module attributes: `@t_min 13.0`, `@t_max 25.0`, `@t_rise 21_600` (06:00), `@t_peak 54_000` (15:00), `@tau_night 10_800`, `@sky_drop 10.0`. Derived: `ΔT = 12.0`, `L = 32_400`, `S_n = 54_000`, `e_n = exp(-S_n/τ_n) = exp(-5)`.

`air_c(time)` with `tod = Calendar.time_of_day(time)`:

- `t_rise ≤ tod < t_peak`: `t_min + ΔT·sin(π/2 · (tod − t_rise)/L)`
- otherwise, with `s = Integer.mod(tod − t_peak, 86_400)` (so `s ∈ [0, S_n)`): `t_min + ΔT·(exp(−s/τ_n) − e_n)/(1 − e_n)`

Continuous at both joins (13.00 at 06:00, 25.00 at 15:00). Reference: 04:00 13.08, 12:00 23.39, 15:00 25.00, 19:00 16.10, 22:00 14.09. Daily mean 17.314.

`mean_air_c(t0, t1)` for `t1 > t0`, exact:

```
D(u) = t_min·u + ΔT·(2L/π)·(1 − cos(π·u/(2L)))                        u ∈ [0, L]
N(s) = t_min·s + ΔT·(τ_n·(1 − exp(−s/τ_n)) − s·e_n)/(1 − e_n)          s ∈ [0, S_n]
G(tod) = if tod < t_rise: N(32_400 + tod) − N(32_400)
         elif tod < t_peak: G_rise + D(tod − t_rise)
         else: G_peak + N(tod − t_peak)
G_rise = N(S_n) − N(32_400);  G_peak = G_rise + D(L);  G_day = G_peak + N(32_400) = 1_495_921 (±1)
mean_air_c(t0, t1) = (G_day·(floor_div(t1, 86_400) − floor_div(t0, 86_400)) + G(mod(t1, 86_400)) − G(mod(t0, 86_400))) / (t1 − t0)
daily_mean_air_c() = G_day / 86_400
```

`sky_c(time) = air_c(time) − 10.0`; `mean_sky_c(t0, t1) = mean_air_c(t0, t1) − 10.0`.

### 2.3 run / prepare

`prepare` sets `env.air_c`, `env.sky_c` for `region.time`. `run` sets them for `Tick.end_time(tick)`. No events.

## 3. `Avwe.Systems.Daylight.mean_light/2` (new)

With `r = @sunrise`, `W = @sunset − @sunrise = 46_800`:

```
G_L(tod) = 0                                     tod ≤ r
         = (W/π)·(1 − cos(π·(tod − r)/W))        r < tod < r + W
         = 2W/π = 29_794.2                        tod ≥ r + W
mean_light(t0, t1) = (G_L_day·(floor_div(t1, D) − floor_div(t0, D)) + G_L(mod(t1, D)) − G_L(mod(t0, D))) / (t1 − t0)
```

Daily mean `0.34484`. `light/1` unchanged.

## 4. `Avwe.Systems.Heat`

### 4.1 Field: `region.fields.heat`

```elixir
%Avwe.Systems.Heat.Field{
  t_ref_c: 15.0,
  static:  tuple of %{cell: {x, y} | {:background, :grass | :stone},
                      material: Terrain.ground(), area_m2: 100.0 | 1.0,
                      cap_j_k: float,          # C_material * area_m2
                      absorb_m2: float,        # α_material * area_m2
                      river: {reach_k, k_full_w_k} | nil},   # W/K when reach k flows
  index:   %{cell_key => i},                   # position in the tuples
  energy:  tuple of floats,                    # J relative to t_ref_c, DYNAMIC
  bank_cells: %{reach_k => [i]},               # silt cells attached to reach k (steam)
  steaming: tuple of booleans per reach,       # DYNAMIC
  last_step: %{dt: int, sun_mj, air_in_mj, air_out_mj, sky_in_mj, sky_out_mj,
               river_in_mj, river_out_mj, hearths_mj, miracles_mj,
               delta_storage_mj, storage_before_mj, storage_after_mj}
}
```

Ordering: real cells first, row-major (`y`, then `x`), then `{:background, :grass}`, then `{:background, :stone}`. The two background entries are 1 m² pseudo-cells with no river coupling and no sources; they go through the same update and are in the budget with their 1 m² area. The index rebuilds only when a cell is activated (§4.3).

Temperature of cell i: `T_i = t_ref_c + energy_i / cap_i`.

### 4.2 Materials (per m²)

| ground | C (J/m²K) | α | τ no river (h) | k_riv when its reach flows (W/m²K) |
|---|---|---|---|---|
| channel_bed | 1.0e6 | 0.30 | 13.9 | 100 |
| reeds | 1.0e6 | 0.35 | 13.9 | 40 |
| silt | 2.5e6 | 0.35 | 34.7 | `40·exp(−(d − 2)/4)`, `d` = cells to the nearest channel cell (2 < d ≤ 6): 31.2 at 3, 14.7 at 6 |
| clay | 3.0e5 | 0.55 | 4.2 | 0 |
| grass | 2.0e5 | 0.45 | 2.8 | 0 |
| stone | 1.5e5 | 0.60 | 2.1 | 0 |

Shared constants: `@k_air 15.0`, `@k_rad 5.0` (linearised `4εσT³` at 290 K), `@s_peak 800.0` W/m² (clear late-summer noon at `light = 1`), `@f_ground 0.3` (share of a fire's output entering its ground cell), `@steam_dc 8.0`, `@warm_dc 8.0`, `@hot_dc 15.0`, `@cold_dc -2.0`.

Justification: silt is the saturated bank of a warm river, a deep wet mass with a large active layer (`τ_silt/τ_stone ≈ 16`: "silt holds heat"); stone is a dry thin skin over rock that follows the sun within hours. `α` is an effective absorptance folding in evaporation from wet surfaces. `k_riv` is warm seepage from the reach through the bank, falling off with distance. `Heat.materials/0` returns this table; `Heat.tau_s(ground)` returns `C/(k_air + k_rad)`.

Reference day (settled, river flowing at ~34 °C by the town): grass 11.5 at 04:00 → 35.2 at 16:00; stone 11.0 → 41.0; clay 13.1 → 36.0; dry silt 18.8–21.0; silt at d = 3 beside the flowing reach 27.0–29.8 (29.6 at 19:00 against air 16.1: steam); silt at d = 6 27.0 at dusk. After the river stops, bank silt at 19:00 falls 25.2, 23.1, 22.0, 21.5, 21.2 over five days and never steams again (+4.9 at best). Dry silt at 04:00 is +5.7 over the air: under the `:warm` band by design.

### 4.3 prepare/1

If `region.terrain` is `nil`: no field is created and `run/2` is a no-op returning `{region, []}` (mirrors `River.run/2`). Otherwise:

1. Active set = every cell within distance ≤ 6.5 of any channel cell (13×13 window per channel cell, filtered by `Space.distance`, clamped to the map) ∪ every cell within each `terrain.clay` patch ∪ the `:position` of every entity with a `:hearth`. Dedupe, sort row-major. For each: `material = Terrain.ground(terrain, cell)`; `river = {Terrain.reach_of(terrain, index), k_riv(material, d)·100}` from `Terrain.nearest_channel/2` when `material ∈ [:channel_bed, :reeds, :silt]`, else `nil`. `bank_cells[k]` = the silt cells with `river = {k, _}`. Append the two backgrounds. About 3 300 cells; ~80 ms. The 65 536-cell scan is never done.
2. River-era reaches: `River.steady_reaches(terrain, spring.natural_m3_s, spring.temp_c, Weather.daily_mean_air_c())` (§5).
3. Initialise every cell at its daily-mean equilibrium: `T_eq` of §4.4 with `T̄_air = daily mean`, `T̄_sky = daily mean − 10`, `L̄ = 0.34484`, the river-era reaches, and sources from standing miracles only (`f_ground·heat_w`).
4. `stopped = if spring.flow_m3_s == 0 and spring[:changed_at], do: min(region.time − changed_at, 14·86_400), else: 0`. Advance with `step_field/5` from `region.time − stopped − 2·86_400` to `region.time − stopped` in 3 600 s steps with the river-era reaches (sets the diurnal phase).
5. If `stopped > 0`: advance from `region.time − stopped` to `region.time` in 3 600 s steps plus one remainder step, with the region's *current* (already settled) reaches. The first ≤ 4 h of this replay use silent reaches that were in fact still draining; the error is under 0.1 K and is accepted.

Cost ≤ 385 steps × 0.5 ms ≈ 0.2 s per build. The budget is discarded; `last_step` starts zeroed with `dt: 0`. `steaming` is computed from the final state.

**Activation on demand.** In `run/2`, if a hearth or standing-miracle entity sits at a cell with no index entry, `activate(field, terrain, cell)` inserts it in row-major position with `material = Terrain.ground(terrain, cell)`, `river` as in step 1, and `energy = 100 · background_energy_per_m2(material)` (for silt/reeds/bed/clay this cannot happen; they are all active). Because open cells of one material evolve identically, the activated cell's state is exactly what the dense field would hold. Tuples are rebuilt (rare; microseconds).

### 4.4 Per-step update: `run/2` and `step_field/5`

Inputs: `t0 = tick.time`, `t1 = Tick.end_time(tick)`, `dt`, `T̄_air = Weather.mean_air_c(t0, t1)`, `T̄_sky = T̄_air − 10`, `L̄ = Daylight.mean_light(t0, t1)`, `reaches = Region.get(region, River.id(), :river).reaches` (end of step; `{}` when there is no river), `sources :: %{i => {hearth_ground_j, miracle_ground_j}}` built by folding `Region.with_components(region, [:hearth, :position])` (sorted) and adding `hearth.last_step.ground_j` under the first or second slot according to `last_step.miracle?`.

`step_field(field, forcing, sources, reaches, dt)` is public and pure (`forcing = %{air_c, sky_c, light}`), used by `run`, `prepare` and the tests. For each cell i in tuple order (`Enum.map_reduce` over `0..n-1`):

```
A     = area_m2;  cap = cap_j_k;  E = energy_i;  T0 = t_ref + E/cap
k_riv = case river do {k, kw} when not elem(reaches, k).silent -> kw / A; _ -> 0.0 end   # W/m²K
T_w   = elem(reaches, k).temp_c            (only when k_riv > 0)
K     = k_air + k_rad + k_riv              # W/m²K, ≥ 20
Q_w   = A·s_peak·α·L̄ + (hearth_j + miracle_j)/dt           # W
T_eq  = (A·(k_air·T̄_air + k_rad·T̄_sky + k_riv·T_w) + Q_w) / (K·A)
x     = dt·K / C_material                  # = dt·K·A/cap
m(x)  = (1 − exp(−x))/x                    # 1 − x/2 + x²/6 when x < 1e-5
T_bar = T_eq + (T0 − T_eq)·m(x)            # time-mean of the exact solution over the step
q_air = A·k_air·(T̄_air − T_bar)·dt         # J, signed, + into the ground
q_sky = A·k_rad·(T̄_sky − T_bar)·dt
q_riv = A·k_riv·(T_w − T_bar)·dt
q_sun = A·s_peak·α·L̄·dt
q_h   = hearth_j;  q_m = miracle_j
dE    = q_air + q_sky + q_riv + q_sun + q_h + q_m
E'    = E + dE
```

Identity: `dE = K·A·(T_eq − T_bar)·dt = cap·(T_eq − T0)·(1 − e^{−x}) = cap·(T1 − T0)` with `T1 = T_eq + (T0 − T_eq)·e^{−x}` the exact solution at `t1`. So `E'` is the exact solution's energy, and the six q terms sum to the storage change up to one rounding each.

Accumulators (Neumaier compensated `{sum, c}` each, in cell order): `sun += q_sun`; `air_in += max(q_air, 0)`; `air_out += max(−q_air, 0)`; likewise `sky_*`, `river_*`; `hearths += q_h`; `miracles += q_m`; `delta += dE`; `storage_before += E`; `storage_after += E'`; per reach `bank_sum[k] += (T1 − air_c_end)` over `bank_cells[k]`. Convert to MJ (÷ 1e6) into `last_step`.

**dt-stability.** `0 < e^{−x} < 1` for every `dt > 0`, so `T1` lies between `T0` and `T_eq`; `T_eq` is a convex combination of `T̄_air`, `T̄_sky`, `T_w` plus `Q_w/(K·A)`, which is bounded (full sun on stone: `800·0.6/20 = 24 K`; a 5 kW hearth: `0.3·5000/2000 = 0.75 K`; the Last Coal: 0.12 K). No overshoot, no growth, no CFL limit: there is no lateral stencil. Lateral conduction is omitted on purpose: soil diffusivity ~5e-7 m²/s gives ~0.2 m per day against 10 m cells; the mechanism that warms the banks is seepage from the reach, modelled as `k_riv`.

**dt-consistency.** Exact for constant forcing (so 60 × 60 s equals 1 × 3 600 s to rounding). Under diurnal forcing the only error is replacing the forcing by its step mean: `O((K·dt/C)²·ΔT_eq)`; for grass at 1 h (`x = 0.36`) that is ~0.05 K. At `dt = 86 400`, `e^{−x} ≈ 0` for grass/stone/clay (they land on their daily-mean equilibrium) and `e^{−x} = 0.5` for silt (it moves halfway from its 04:00 value to its daily mean): bounded and sensible.

After the loop: `energy`, `last_step`, `steaming` (next), then events.

**Steam.** For each reach k (sorted) with `bank_cells[k] != []`: `steaming_k = not elem(reaches, k).silent and bank_sum[k]/length(bank_cells[k]) ≥ 8.0`, where `air_c_end = Weather.air_c(t1)`. On a flip emit `:steam_rising` / `:steam_fading` with `entity: River.id()`, `data: %{reach: k, position: reach.mid}` (time: end of step). Using the end-of-step air is what makes the banks steam in the evening as the air falls.

### 4.5 Queries (pure, on a snapshot's `fields.heat` plus `terrain`)

- `Heat.ground_c(field, terrain, cell)` → the active cell's `T_i`, else the background of `Terrain.ground(terrain, cell)`.
- `Heat.at(snapshot, cell)` → `%{air_c, ground_c, ground: :hot | :warm | :cold | nil, steam?: boolean}` with `ground − air_c ≥ 15 → :hot`, `≥ 8 → :warm`, `≤ −2 → :cold`; `steam?` = material ∈ `[:channel_bed, :reeds, :silt]` and the nearest reach flows and `ground − air_c ≥ 8`.
- `Heat.steaming?(field, k)`.
- `Heat.sources(view)` → `[%{id, name, position, power_w, kind: :hearth | :miracle}]` for burning hearths and standing miracles, sorted by id.
- `Heat.stored_mj(field)` → Neumaier sum of `energy` / 1e6 (the independent storage computation the tests use).
- `Heat.materials/0`, `Heat.tau_s/1`, `Heat.step_field/5`.

## 5. `Avwe.Systems.River` changes

- Delete `@ambient_c` and `ambient_c/0`.
- `reach_step/6` takes `air_c` and cools toward it: `temp = air + (mixed − air)·exp(−dt/@cooling_s)`. `flow/6` takes `air_c`; `run/2` passes `Weather.mean_air_c(tick.time, Tick.end_time(tick))`.
- `steady_reaches(terrain, flow_m3_s, temp_c, air_c)` is public (the old `steady_state/3` with the air parameter), returning the tuple of reach states. `settle` uses `Weather.daily_mean_air_c()` for it; `drain` carries the start time and passes `Weather.mean_air_c` of each sub-step's own interval.
- The water's energy stays outside the ground budget: the reach is a boundary reservoir (like the air); the ground books what it took as `river_in/out`. The 6 h cooling constant already includes bank loss. One-way, declared.
- `Avwe.Prose.warmth/2` (the only caller of `ambient_c/0`) reads `channel.air_c` (§9) with `@steam_above_air_c 8`.

Existing `river_test.exs` assertions hold (the last reach stays > 30 °C with air 13–25).

## 6. `Avwe.Systems.Fire`

### 6.1 Component

```elixir
hearth: %{fuel_kg: 12.0, burning: false, lit_at: nil | time, out_at: nil | time,
          power_w: 5_000.0, low_kg: 1.0,
          last_step: %{burn_s: 0.0, burned_kg: 0.0, heat_j: 0.0, ground_j: 0.0,
                       vented_j: 0.0, smoke_g: 0.0, miracle?: false}}
```

`@fuel_j_per_kg 16.0e6` (dry wood, lower heating value); burn rate `r = power_w / 16e6` kg/s (5 kW → 1.125 kg/h; 12 kg is a night's fire). `@smoke_g_per_kg 10.0`. A hearth entity also has `:position` and `:repr`.

### 6.2 Standing miracles

An entity carrying both `:hearth` and `miracle: %{kind: :standing, breaks: [:fuel, :dousing], heat_w: 800.0, smoke: false, cause: :unknown, note: ...}` is a hearth that burns without fuel. `Miracles` already ignores `kind != :event`. Fire treats it as: `burning` stays true, `burn_s = dt`, `burned_kg = 0.0`, `heat_j = heat_w·dt`, `smoke_g = 0.0`, `miracle?: true`. `:douse` is blocked with `:unquenchable` when `:dousing ∈ breaks`. Nothing mentions the Last Coal by id.

### 6.3 run/2

For each id in `Region.with_components(region, [:hearth, :position])` (sorted), `t0 = tick.time`:

- not burning: `last_step` zeroed; no events.
- burning, ordinary: `burn_s = min(dt, fuel_kg / r)`; `burned = r·burn_s`; `fuel' = if burn_s < dt, do: 0.0, else: fuel_kg − burned`; `heat_j = power_w·burn_s`; `ground_j = 0.3·heat_j`; `vented_j = heat_j − ground_j`; `smoke_g = burned·10`. If `fuel_kg > low_kg ≥ fuel'`: emit `:fire_low` at `t0 + round((fuel_kg − low_kg)/r)`, `data: %{position}`. If `burn_s < dt`: `burning = false`, `out_at = t0 + round(burn_s)` (integer), emit `:fire_out` at `out_at`, `data: %{position, reason: :fuel, by: nil}`.
- burning, standing miracle: §6.2.

Linear consumption clamped at zero is exact at any dt: 12 kg at 5 kW goes out at `lit_at + 38_400` whatever the stepping. `fuel_before − fuel_after == burned_kg` exactly. Fuel supply (woodpiles, `:feed`) is out of scope.

### 6.4 Verbs (`Avwe.Actions.perform/3`, instant; `Intent` docs and `verb` type gain both)

`hearth_near(region, position)`: ids with `:hearth` and `:position` within `@at_place_cells 2` of `position`, sorted by `{distance, id}`.

- `:kindle`, `target` nil or a hearth id. Checks in order: target nil → nearest from `hearth_near`, none → `:no_hearth`; target given → exists with `:hearth` (`:no_such_hearth`), within 2 cells (`:too_far`); then `:already_burning`; then `fuel_kg > 0` or standing miracle (`:no_fuel`). Success: `burning: true, lit_at: tick.time, out_at: nil`; events `:fire_lit` (`entity: hearth, data: %{position, by: body}`) then the `:action_result` (with `target` filled in). Fire runs later in the same step, so the fire burns from `tick.time`.
- `:douse`, same target resolution; then `:not_burning`; then `:unquenchable`. Success: `burning: false, out_at: tick.time`; events `:fire_out` (`reason: :doused, by: body`) then the result.

Telnet (`Avwe.Telnet.Command`): `kindle`, `light`, `light [the] fire`, `light [the] hearth` → `:kindle`; `douse`, `put out [the] fire` → `:douse`; both with `target: nil`. `help` lists them. `Connection.run/2` maps `:kindle`/`:douse` to `Session.act/3`.

### 6.5 Felt warmth: `Fire.felt(view, position)`

For each burning hearth within 2 cells (`Heat.sources`-style list, sorted): `d_m = max(10·Space.distance(position, hearth_pos), 1.0)`; `w_m2 = 0.5·P/(2π·d_m²)` (radiant half into a hemisphere; `P = power_w`, or `heat_w` for a miracle). Level: `≥ 100 → :hot`, `≥ 20 → :warm`, `≥ 2 → :faint`, else none. Returns the strongest as `%{ref, name, level, w_m2}` or nil. 5 kW: 398 in its cell (`:hot`), 4.0 at 10 m and 2.0 at 14 m (`:faint`), 1.0 at 20 m (nothing). The Last Coal (800 W): 64 in its cell (`:warm`), nothing beyond. Perception only; no energy moves.

## 7. `Avwe.Systems.Smoke`

### 7.1 Field: `region.fields.smoke`

```elixir
%{puffs: [%{x: float, y: float, g: float, born: float}],   # cell coordinates (fractional), grams,
                                                           # mass-weighted emission time; sorted by {born, x, y}
  last_step: %{emitted_g, survived_g, decayed_g, dropped_g, left_g, storage_before_g, storage_after_g}}
```

Constants: `@tau_s 900.0` (dispersion), `@max_age_s 4_500.0` (5τ), `@g_min 0.01`, `@sigma0_m 5.0`, `@spread_m_s 0.3`, map size from `terrain.width` (256 when no terrain).

`drift_cells(wind, seconds)`: with `i` the index of `wind.from` in `Space.directions/0`, `toward = {−sin(iπ/4), cos(iπ/4)}` (a wind *from* the north moves parcels south, +y); returns `toward · wind.m_s · seconds / 10`.

### 7.2 run/2 (`t0`, `t1`, `dt`)

1. Existing puffs, in list order: `g' = g·exp(−dt/τ)`; `decayed += g − g'`; `{x, y} += drift_cells(env.wind, dt)`. If `t1 − born > max_age` or `g' < g_min`: drop, `dropped += g'`. If `x ∉ [0, width)` or `y ∉ [0, width)`: drop, `left += g'`.
2. Emission, one puff per hearth (sorted ids) with `last_step.smoke_g > 0` (ordinary burning hearths; miracles with `smoke: false` emit nothing): `m = smoke_g`, `b = burn_s`, released uniformly over `[t0, t0 + b]`, each parcel decaying until `t1`:

```
f(b)     = (τ/b)·(exp(b/τ) − 1)        # 1 + b/(2τ) + b²/(6τ²) when b/τ < 1e-3
survived = m·exp(−dt/τ)·f(b)
mean_age = dt − b + τ − b/(exp(b/τ) − 1)      # dt − b/2 when b/τ < 1e-3
puff = %{g: survived, born: t1 − mean_age,
         x: hx + 0.5 + drift_x(mean_age), y: hy + 0.5 + drift_y(mean_age)}
emitted += m;  survived_g += survived;  decayed += m − survived
```

For `dt ≪ τ` this is `m` at age `dt/2` just downwind; for `dt ≫ τ` it is `m·τ/dt` at the steady plume's centre of mass. Total mass is exact at any dt; only the plume's shape coarsens to one puff per hearth per step when steps are an hour or longer. A new puff is also dropped at once if `survived < g_min` (counted in `dropped`).
3. `storage_after = Σ g` (Neumaier, list order). Identity: `storage_after − storage_before == emitted − decayed − dropped − left`.
4. Bound: puffs alive per hearth ≤ `ceil(max_age/dt) + 1` (≤ 76 at dt = 60, 2 at dt = 3 600), independent of history: 20 hearths → ≤ 1 520 puffs.
5. Smell, for each body id in `Region.with_components(region, [:body, :position])` (sorted): `density_g_m2(field, cell, t1) = Σ_i g_i/(2π·σ_i²)·exp(−d_i²/(2σ_i²))`, `σ_i = 5 + 0.3·(t1 − born_i)` m, `d_i` = metres from the body's cell centre `{x + 0.5, y + 0.5}` to `{x_i, y_i}`. Level: `≥ 1e-3 → :thick`, `≥ 1e-4 → :clear`, `≥ 1e-5 → :faint`, else `:none`. The level lives in the body's `:nose` component (`%{smoke: level}`, missing = `:none`); on change emit `:smoke_smelled` (`entity: body, data: %{level, from: env.wind.from}`) or `:smoke_faded` (`data: %{}`), and write the component. Reference: a fresh 60 s puff from a 5 kW hearth (0.1875 g) is 1.2e-3 g/m² at the hearth (`:thick`); ~1e-5 300 m downwind at 2 m/s (`:faint`); nothing upwind beyond σ.

`Smoke.density_g_m2/3` and `Smoke.level/1` are public for `Perception.look`.

## 8. Worldgen and config

`config/config.exs`, under `ember_reach`:

```elixir
climate: [wind: [from: "south-west", m_s: 2.0]],
hearths: [
  [id: "town-hearth", at: "ember-reach", name: "the kiln-house hearth", fuel_kg: 8.0, power_w: 5_000.0],
  [id: "lodge-hearth", at: "ashwarden-lodge", name: "the lodge hearth", fuel_kg: 12.0, power_w: 5_000.0]
],
miracles: [
  [ ...the-source-fails, unchanged... ],
  [id: "the-last-coal", kind: :standing, at: "ashwarden-lodge", heat_w: 800.0,
   breaks: [:fuel, :dousing], cause: :unknown,
   note: "Heat without fuel, declared: the Last Coal does not eat wood."]
]
```

`Worldgen.region/2`:
- `add_climate/2`: `Region.put_env(:wind, %{from, m_s})` (default `%{from: "south-west", m_s: 2.0}` when absent).
- `add_hearths/2`: each entry → `put_entity(id, %{hearth: %{fuel_kg, burning: false, lit_at: nil, out_at: nil, power_w, low_kg: 1.0, last_step: zero}, position: position_of(at), repr: %{name, description: nil}})`.
- `add_miracles/2`: an entry with `kind: :standing` → `put_entity(id, %{position: position_of(at), repr: %{name: article.title, description: article.summary}` (from `quire_world.articles[id]` when it exists, else `name`/`description` keys), `hearth: %{fuel_kg: 0.0, burning: true, lit_at: nil, out_at: nil, power_w: heat_w, low_kg: 0.0, last_step: zero}, miracle: %{kind: :standing, breaks, heat_w, smoke: false, cause, note}})`. Event miracles unchanged.

`Avwe.Test.Ember.region/2` passes `hearths: opts[:hearths]`, `climate: opts[:climate]` and uses the §1 order. `Avwe.start_world/2` reads the same keys.

## 9. Perception and prose

`Perception.look/2` for a body (the snapshot carries `fields` and `terrain`; when `view[:fields][:heat]` is absent, `warmth` and `smoke` are `nil`):

```elixir
warmth: %{air_c, ground_c, ground: :hot | :warm | :cold | nil, steam?: bool, fire: %{ref, name, level} | nil}
smoke:  %{level: :faint | :clear | :thick, from: direction} | nil
hearth: %{id, name, burning, fuel_kg, distance_m} | nil                # nearest within 2 cells
fires:  [%{ref, name, distance_m, direction, sign: :smoke | :glow}]    # burning hearths within max(sight_cells(light), 20) cells; :glow when light < 0.1
channel: ... existing keys plus air_c: env.air_c
```

Affordances: `%{verb: :kindle, targets: [ids]}` for hearths within 2 cells that are not burning and have fuel (or are miracles); `%{verb: :douse, targets: [ids]}` for burning, quenchable ones. Spectator `look` adds `fires: [%{id, name, burning, fuel_kg}]` and `heat: %{air_c, steaming_reaches: [k]}`.

`Percept.modality` gains `:smell`.

Percepts (`Perception.percepts/3`, view only):
- `:fire_lit`, `:fire_out`, `:fire_low`: seen within `max(sight_cells(light), 20)` cells (a fire is its own light), modality `:sight`, salience 0.7 / 0.6 / 0.5; spectators always. Own kindling also returns the `:action_result`.
- `:steam_rising` / `:steam_fading`: the `hear_river` nearest-reach rule (within 12 cells, same reach), modality `:sight`, salience 0.6; spectators once per place along the river as `hear_river` does.
- `:smoke_smelled` / `:smoke_faded`: only for `event.entity == body`, modality `:smell`, salience 0.5 (faint) / 0.7 (clear, thick).
- `:miracle` stays game-master only.

`Prose` strings (exact):
- warmth: `"The air is cool."` (air < 15) / `"The air is warm."` (≥ 22); ground `:hot` → `"The ground is hot underfoot."`, `:warm` → `"The ground is warm underfoot."`, `:cold` → `"The ground is cold."`; `steam?` appends `" Steam lifts off the silt."` / `"...the reeds."` / `"...the water."` by material; fire `:hot` → `"The fire's heat is on your face."`, `:warm` → `"Warmth reaches you from #{name}."`, `:faint` → `"You feel a faint warmth from #{name}."`
- channel: `warmth/2` keeps `", warm"` at ≥ 30 °C and `", with steam lifting off it"` when `light < 0.3 and temp_c − air_c ≥ 8`.
- smoke: `"Woodsmoke, faint, from the #{from}."` / `"Woodsmoke on the wind from the #{from}."` / `"The smoke is thick here."`; fires: `"Smoke rises from #{name}, #{d} m to the #{dir}."` / `"A glow shows at #{name}, #{d} m to the #{dir}."`
- hearth: `"#{Name} is burning here."` / `"#{Name} is cold, with wood laid."` / `"#{Name} is cold and empty."`
- events: `"#{who} lights #{name}."` / `"You light #{name}."`, `"The fire burns low."`, `"The fire goes out."` (reason `:fuel`), `"#{who} douses #{name}."` / `"You douse #{name}."`, `"Steam begins to rise from the banks."`, `"The steam over the banks thins and is gone."`, `"You smell woodsmoke, faint, from the #{from}."`, `"The smell of smoke fades."`
- results: kindle `:no_hearth` → `"There is no hearth here."`, `:no_such_hearth` → `"There is no such hearth."`, `:too_far` → `"You are not close enough."`, `:no_fuel` → `"There is nothing to burn."`, `:already_burning` → `"It is already lit."`; douse `:not_burning` → `"It isn't lit."`, `:unquenchable` → `"It does not go out."`

## 10. Budget records and invariants

`fields.heat.last_step` (MJ, every line ≥ 0 except the signed `delta_storage_mj` and the storage totals, which are relative to 15 °C):

```
delta_storage_mj == sun_mj + air_in_mj − air_out_mj + sky_in_mj − sky_out_mj + river_in_mj − river_out_mj + hearths_mj + miracles_mj     (|residual| ≤ 1e-6)
storage_after_mj − storage_before_mj == delta_storage_mj                                                                                  (|residual| ≤ 1e-6)
storage_before_mj == Heat.stored_mj(field before)                                                                                          (|residual| ≤ 1e-6)
miracles_mj == 0.3 · Σ_standing heat_w · dt / 1e6;  hearths_mj == 0.3 · Σ_ordinary hearth.last_step.heat_j / 1e6
```

Rounding margin: `|E_i| ≤ 2.5e8 J/K · 25 K ≈ 6e9 J`; Neumaier's bound `eps·|S| ≈ 2e-16 · 1e13 = 2e-3 J` on the storage totals and far less on the lines, against the 1 J tolerance.

`hearth.last_step`: `heat_j == ground_j + vented_j`, `burned_kg == fuel_before − fuel_after`, `smoke_g == 10·burned_kg`.

`fields.smoke.last_step`: `storage_after_g − storage_before_g == emitted_g − decayed_g − dropped_g − left_g` within 1e-9 g; `emitted_g == Σ hearth.last_step.smoke_g` within 1e-9.

## 11. Public functions

```elixir
Avwe.Systems.Weather.air_c(time) :: float
Avwe.Systems.Weather.sky_c(time) :: float
Avwe.Systems.Weather.mean_air_c(t0, t1) :: float
Avwe.Systems.Weather.daily_mean_air_c() :: float
Avwe.Systems.Daylight.mean_light(t0, t1) :: float
Avwe.Systems.Heat.step_field(field, %{air_c, sky_c, light}, sources, reaches, dt) :: {field, last_step}
Avwe.Systems.Heat.ground_c(field, terrain, cell) :: float
Avwe.Systems.Heat.at(snapshot, cell) :: map
Avwe.Systems.Heat.steaming?(field, k) :: boolean
Avwe.Systems.Heat.sources(view) :: [map]
Avwe.Systems.Heat.stored_mj(field) :: float
Avwe.Systems.Heat.materials() :: map
Avwe.Systems.Heat.tau_s(ground) :: float
Avwe.Systems.River.steady_reaches(terrain, flow_m3_s, temp_c, air_c) :: tuple
Avwe.Systems.Fire.felt(view, cell) :: map | nil
Avwe.Systems.Fire.hearth_near(region_or_view, cell) :: [{id, hearth, distance}]
Avwe.Systems.Smoke.drift_cells(wind, seconds) :: {float, float}
Avwe.Systems.Smoke.density_g_m2(field, cell, time) :: float
Avwe.Systems.Smoke.level(density) :: :none | :faint | :clear | :thick
```

## 12. Cost (measured basis, M4 Max, plain Elixir)

The exact-relaxation loop with all accumulators: 0.45 ms for 3 500 cells (2.1 ms at 16 384, 9.0 ms at 65 536). Per step: Heat ≈ 0.5 ms (3 300 cells + 2 backgrounds + steam sums); Smoke ≤ 1 500 puffs × (drift, decay) + bodies × puffs ≈ 0.3 ms; Fire and Weather microseconds; ETS copy of `fields.heat` (~350 KB, static included) ≈ 0.3 ms. Total ≈ 1.5 ms, independent of dt, against the 20 ms bound. If per-cell forcing (shade, wetness) ever arrives, activating every cell costs the measured 9 ms and nothing else changes. Prepare ≈ 0.3 s. Nx is not needed.

## 13. Tests

`test/avwe/systems/weather_test.exs`
1. `mean_air_c(t, t + 86_400) == daily_mean_air_c()` within 1e-9 for `t` in {0, 813/220 04:00, 812/200 15:00 + 17}; the 1 s trapezoid of `air_c` over a day matches `G_day` within 1.0.
2. `air_c` is continuous at 06:00 and 15:00 (|jump| < 1e-9), lies in [13, 25], and gives 16.10 ± 0.01 at 19:00.
3. `mean_air_c(t0, t2)·(t2 − t0) == mean_air_c(t0, t1)·(t1 − t0) + mean_air_c(t1, t2)·(t2 − t1)` within 1e-6 (property, random `t0 < t1 < t2` across a day boundary).

`test/avwe/systems/daylight_test.exs` additions: `mean_light(t, t + 86_400) == 0.34484 ± 1e-4`; over [12:00, 13:00] ≈ 0.99 ± 0.01; over the night 0.0; the mean of 24 hourly means equals the daily mean within 1e-9.

`test/avwe/systems/heat_test.exs` (region from `Ember.region/2`, systems `[Daylight, Miracles, Weather, River, Fire, Heat]`)
4. **Conservation property** (`max_runs: 25`): `steps <- list_of(member_of([60, 600, 3_600, 21_600, 86_400]), min_length: 1, max_length: 8)`, `minutes_before <- integer(-240..240)` around 812/200 15:00, `kindle? <- boolean()` (a `:kindle` for `mira-vale` submitted before the first step). For each step: `s0 = Heat.stored_mj(before)`; advance; `b = last_step`; assert the three identities of §10 within 1e-6 MJ; every `*_in`, `*_out`, `sun`, `hearths`, `miracles` ≥ 0 and finite; `miracles_mj == 0.3·800·dt/1e6 ± 1e-9`; `hearths_mj == 0.3·Σ ordinary heat_j/1e6 ± 1e-9`.
5. **Boundedness**: 60 steps of 86 400 s then 1 440 of 60 s from the 813 start: every cell and background within [5, 55] °C, never NaN; synthetic one-cell `step_field` with constant forcing: `T1` between `T0` and `T_eq` for dt in {1, 60, 3 600, 86 400, 864 000}.
6. **Exactness under constant forcing**: `step_field` with fixed `%{air_c: 20, sky_c: 10, light: 0.5}`, a hearth source and flowing reaches: 60 × 60 s and 1 × 3 600 s agree in `stored_mj` to 1e-9 relative and per cell to 1e-9 K.
7. **dt-consistency (diurnal)**: from 812/200 07:00 with the town hearth lit: `advance(60, dt: 60)` vs `advance(1, dt: 3_600)`: max |Δground_c| over all cells ≤ 0.15 °C; same from 19:00. One world day from 812/200 04:00: 1 440 × 60 s vs 24 × 3 600 s: max |Δ| ≤ 0.5 °C at every hour, `stored_mj` within 0.5 %, every budget line within 3 %. One 86 400 s step vs the hourly run's per-cell daily mean: grass, stone, clay within 0.1 K; silt, reeds, bed within 1.0 K.
8. **Silt holds heat longer than stone**: `tau_s(:silt) / tau_s(:stone) ≥ 10`; from the settled 16:00 state, after 4 h of 60 s steps the stone background has lost > 60 % of its excess over the air and a dry silt cell (chosen by `Terrain.ground == :silt`, nearest reach silent or `d = 6`) < 10 %.
9. **The banks steam at dusk, with the river**: 812/200 19:30: a silt cell at `d = 3` beside the reach nearest the town (found by scanning `bank_cells`) gives `Heat.at` `steam?: true` and `ground − air ≥ 8`; at 13:00 `steam?: false`; advancing 18:00 → 20:00 at 60 s emits ≥ 1 `:steam_rising`, upstream reaches first.
10. **The silt cools after the source fails**: advance 10 days at 3 600 s from 812/200 15:00: the bank cell's 19:00 value falls monotonically and ends within 1 °C of 21.0; no `:steam_rising` after day 1; `:steam_fading` arrives reach by reach, upstream first.
11. **A year later the banks are cold**: `Ember.region({813, day: 220, hour: 19})`: `steaming == {false, ...}`, bank silt within 1 °C of dry silt; at 04:00 and 19:00 dry silt is not `:warm`.
12. **River couples only when flowing**: `river_in_mj > 0` on a night step in 812; `river_in_mj == river_out_mj == 0.0` exactly in 813.
13. **Activation**: a hearth put on an open grass cell after prepare and kindled: the cell appears in `index`, its first energy equals `100 ×` the grass background, and `hearths_mj` books its heat.
14. **No terrain**: a region without terrain runs `[Weather, Heat]` with no field and `env.air_c` set.
15. **Determinism**: `state_hash` equal for 1 × 3 600 vs 60 × 60? No: for the same step list run twice, and for 30 × 60 many-at-once vs one-at-a-time; and seed-independence: regions with seeds 1 and 2 (same terrain seed via opts) have identical `fields.heat`, `fields.smoke` and `:hearth` components after 100 steps (these systems never draw from `Tick.rng`).
16. **Cost** (`@tag :perf`): 200 steps with all systems at dt = 60: mean < 10 ms (bound 20), expected ≈ 2 ms, logged.

`test/avwe/systems/river_test.exs` additions: existing tests unchanged; "water is cooler at dawn than at dusk" (last reach at 05:00 vs 17:00 after a day of 60 s steps: ≥ 0.5 K).

`test/avwe/systems/fire_test.exs`
17. 12 kg at 5 kW: `:fire_low` at the exact second 1 kg remains, `:fire_out` stamped `lit_at + 38_400` and `out_at` set, whether stepped at 60, 3 600 or 86 400 s; `fuel_kg == 0.0`; Σ `burned_kg == 12.0 ± 1e-9`; `heat_j == ground_j + vented_j` each step.
18. The Last Coal burns a day with `fuel_kg == 0.0`, `burned_kg == 0`, `heat_j == 800·dt`, `smoke_g == 0`; `:douse` on it is `:unquenchable`.
19. Verbs: at the town hearth `kindle` (no target) → `:fire_lit`, `burning: true`, `:douse` in affordances; again → `:already_burning`; `douse` → `:fire_out` reason `:doused`; `douse` cold → `:not_burning`; 30 m away → `:no_hearth`; `target: "lodge-hearth"` from the town → `:too_far`; unknown id → `:no_such_hearth`; a hearth with `fuel_kg: 0.0` → `:no_fuel`. `Command.parse("light the fire") == :kindle`, `parse("put out the fire") == :douse`.
20. Felt: `Fire.felt` at the lodge is `:warm` from the Last Coal and `:hot` with the lodge hearth lit; `:faint` one cell away; nil two cells away.

`test/avwe/systems/smoke_test.exs`
21. **Conservation property**: dt in {60, 600, 3 600, 86 400}, hearth lit: the §10 smoke identity within 1e-9 g each step; `emitted_g == Σ smoke_g`; all lines ≥ 0.
22. **dt-consistency**: lodge hearth lit at 10:00, wind `%{from: "north", m_s: 2.0}`: after 1 × 3 600 vs 60 × 60, total mass equal within 1e-9 g and the mass-weighted mean position within 0.5 cells.
23. **Downwind, not upwind**: a body 300 m south of the lodge gets `:smoke_smelled` within 5 minutes of kindling, a body 300 m north never does; after `:douse`, `:smoke_faded` arrives within 20 minutes; puff count per hearth ≤ 76 at dt = 60; two hours after the fire is out, `puffs == []`.

`test/avwe/perception_test.exs` additions: `look` at the lodge shows `warmth.fire.level == :warm`; `fires` lists a burning hearth 150 m away at night with `sign: :glow` and not one 600 m away; affordances include `:kindle` only within 2 cells; `look` without `fields` gives `warmth: nil`; prose lines of §9 appear verbatim.

`test/e2e/fire_test.exs` (telnet, Ember at 813/220 04:00, Mira at the town): `kindle` → `"You light the kiln-house hearth."`; `look` → `"The kiln-house hearth is burning here."` and `"The fire's heat is on your face."`; a watcher sees `"Mira Vale lights the kiln-house hearth."`; `douse` → `"You douse the kiln-house hearth."`; `light the fire` then `Avwe.step(world, 8·60·60/60)` hours until `"The fire burns low."` then `"The fire goes out."` arrive in that order with the out time `lit + 25_600` s.

`test/e2e/session_test.exs` additions: `Session.act(mira, :kindle)` returns a ref whose `:result` percept has `outcome: :success`; a second session on a body 300 m downwind (wind set from the north in `ember_reach_opts`) receives a `:smoke_smelled` percept with `modality: :smell`.

`test/e2e/river_test.exs` additions: Ember at 812/200 18:00, Mira walks `east 30` onto the silt; stepping to 20:00 yields `"Steam begins to rise from the banks."` and `look` shows `"Steam lifts off the silt."`; the existing three tests unchanged (the 17:00 `look` still says `"The old channel runs 60 m to the east."`).