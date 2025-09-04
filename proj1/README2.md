# Project 1 — README (Sums of Consecutive Squares)

**Environment**
- OS: macOS (local laptop; Apple M4, 10 cores)
- Gleam: gleam 1.12.0
- Command used: `time gleam run 1000000 4 <batch_size>`

---

## 1) Best work-unit size (batch size) and how it was determined

**Best batch size (work-unit size):** `50000`

**How it was determined:**  
I ran benchmark trials of the program for `N = 1_000_000` and `k = 4` using several batch sizes and compared wall-clock (REAL) time and the CPU/REAL ratio. The runs tested and their measured timing are shown below. Batch size `50000` gave the lowest REAL time (0.159 s) and the highest CPU/REAL ratio (~2.64), meaning it completed fastest while using the most CPU in parallel. Smaller batch sizes (e.g. 50) spent far more wall-clock time due to spawn/message overhead and therefore lower parallelism in effect.

**Tested batch sizes:** `50`, `500`, `5000`, `50000` (single-run timings shown below).

---

## 2) Program output for `lukas 1000000 4` (examples & raw timing)

I ran the program with several batch sizes. Here is the exact console output you provided (including the timing printed by the shell `time`):

```
$ time gleam run 1000000 4 50
   Compiled in 0.01s
    Running first.main
Number of chunks: 20000
src/first.gleam:45
[]
gleam run 1000000 4 50  3.10s user 0.27s system 114% cpu 2.944 total

$ time gleam run 1000000 4 500
   Compiled in 0.02s
    Running first.main
Number of chunks: 2000
src/first.gleam:45
[]
gleam run 1000000 4 500  0.26s user 0.18s system 205% cpu 0.215 total

$ time gleam run 1000000 4 5000
   Compiled in 0.01s
    Running first.main
Number of chunks: 200
src/first.gleam:45
[]
gleam run 1000000 4 5000  0.24s user 0.18s system 256% cpu 0.163 total

$ time gleam run 1000000 4 50000
   Compiled in 0.01s
    Running first.main
Number of chunks: 20
src/first.gleam:45
[]
gleam run 1000000 4 50000  0.24s user 0.18s system 262% cpu 0.159 total
```
---

## 3) Timing for `lukas 1000000 4` (selected best run)

I selected the best-performing run (batch size `50000`) and computed the CPU/REAL ratio from the timing line the shell printed.

**Raw timing line (best run):**
```
gleam run 1000000 4 50000  0.24s user 0.18s system 262% cpu 0.159 total
```

**Computed times:**
- CPU time = user + system = `0.24 + 0.18 = 0.42` seconds
- REAL (wall-clock) time = `0.159` seconds
- CPU / REAL ratio = `0.42 / 0.159 ≈ 2.64`

**Interpretation:** on average the program used about 2.64 CPU-seconds per wall-second, i.e. roughly 2.6 cores worth of CPU time. This indicates effective parallelism (significantly > 1). The best wall-clock completion among the tested batch sizes was for `batch_size = 50000` (0.159 s).

For comparison, the other runs show:
- batch 50: CPU = 3.10 + 0.27 = `3.37` s; REAL = `2.944` s → ratio ≈ `1.15` (very little parallelism; high overhead)
- batch 500: CPU = 0.26 + 0.18 = `0.44` s; REAL = `0.215` s → ratio ≈ `2.05`
- batch 5000: CPU = 0.24 + 0.18 = `0.42` s; REAL = `0.163` s → ratio ≈ `2.58`
- batch 50000 (chosen): CPU = `0.42` s; REAL = `0.159` s → ratio ≈ `2.64`

---

## 4) Largest problem solved

-  **Largest N solved to completion:**  `N = 100,000,000` with `k = 20`.

-  **Batch size used:**  `10000`

**Exact console output (run command and output):**

```
$ time gleam run 100000000 20 10000

Compiled in 0.02s
Running first.main

Number of chunks: 10000
src/first.gleam:45
[62780852, 88700958]

gleam run 100000000 20 10000 19.85s user 2.59s system 253% cpu 8.857 total
```
