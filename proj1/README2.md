# Project 1 — README (Sums of Consecutive Squares)

**Environment**
- OS: macOS (local laptop; Apple M4, 10 cores)
- Gleam: gleam 1.12.0
- Command used: `time gleam run N k <batch_size>`

---

## 1) Best work-unit size (batch size) and how it was determined

**Best batch size (work-unit size):** around `1000 – 10000`

**How it was determined:**  
I ran benchmark trials for `N = 1,000,000` and `k = 4` using multiple batch sizes. The results show that very small batches (like 50) suffer from overhead and lead to poor performance, while very large batches (like `1,000,000`) reduce parallelism and increase real time. The sweet spot was around `1000–10000`, which minimized wall-clock (REAL) time while maintaining a high CPU/REAL ratio.

---

## 2) Program output for `lukas 1000000 4`

Below are the benchmark runs for `N = 1,000,000`, `k = 4`, and different batch sizes:


```

$ time gleam run 1000000 4 50  
Number of chunks: 20000, batch size: 50  
gleam run 1000000 4 50 4.07s user 0.26s system 109% cpu 3.940 total

$ time gleam run 1000000 4 100  
Number of chunks: 10000, batch size: 100  
gleam run 1000000 4 100 1.22s user 0.22s system 128% cpu 1.121 total

$ time gleam run 1000000 4 1000  
Number of chunks: 1000, batch size: 1000  
gleam run 1000000 4 1000 0.20s user 0.16s system 268% cpu 0.134 total

$ time gleam run 1000000 4 10000  
Number of chunks: 100, batch size: 10000  
gleam run 1000000 4 10000 0.22s user 0.16s system 305% cpu 0.124 total

$ time gleam run 1000000 4 100000  
Number of chunks: 10, batch size: 100000  
gleam run 1000000 4 100000 0.21s user 0.17s system 265% cpu 0.145 total

$ time gleam run 1000000 4 1000000  
Number of chunks: 1, batch size: 1000000  
gleam run 1000000 4 1000000 0.19s user 0.17s system 177% cpu 0.201 total

```

---

## 3) Timing and CPU/REAL ratios for `lukas 1000000 4`

- **Batch 50**: CPU = 4.07 + 0.26 = `4.33` s, REAL = `3.940` s → ratio ≈ `1.10`
- **Batch 100**: CPU = 1.22 + 0.22 = `1.44` s, REAL = `1.121` s → ratio ≈ `1.28`
- **Batch 1000**: CPU = 0.20 + 0.16 = `0.36` s, REAL = `0.134` s → ratio ≈ `2.69`
- **Batch 10000**: CPU = 0.22 + 0.16 = `0.38` s, REAL = `0.124` s → ratio ≈ `3.06`
- **Batch 100000**: CPU = 0.21 + 0.17 = `0.38` s, REAL = `0.145` s → ratio ≈ `2.62`
- **Batch 1000000**: CPU = 0.19 + 0.17 = `0.36` s, REAL = `0.201` s → ratio ≈ `1.79`

**Interpretation:** Parallelism improves greatly once the batch size exceeds 100, with the best CPU/REAL ratio at batch size `10000` (≈3.06). This shows the program effectively used about 3 cores worth of compute in parallel on that run.

---

## 4) Largest problems solved

### Large N run 1

```

$ time gleam run 99999999 9999999 99999  
Number of chunks: 1001  
[2529841, 2206205, 4783899, 4511039, ..., 93179807]

gleam run 99999999 9999999 99999 21.45s user 1.77s system 930% cpu 2.495 total

```

- CPU time = 21.45 + 1.77 = `23.22` s  
- REAL = `2.495` s  
- CPU/REAL ≈ `9.3` → used 9+ cores effectively.

---

### Large N run 2

```

$ time gleam run 999999999 9999999 99999  
Number of chunks: 10001  
[4370052, 5863969, 5865515, ..., 994989292]

gleam run 999999999 9999999 99999 248.13s user 16.98s system 867% cpu 30.562 total

```

- CPU time = 248.13 + 16.98 = `265.11` s  
- REAL = `30.562` s  
- CPU/REAL ≈ `8.67` → used about 8–9 cores effectively.

---

### Large N run 3

```
$ time gleam run 100000000 20 500000
Number of chunks: 200, batch size: 500000
[62780852, 88700958]
gleam run 100000000 20 500000 22.28s user 2.85s system 938% cpu 2.679 total
```
 
- CPU time = 22.28 + 2.85 = `25.13` s
- REAL = `2.679` s
- CPU/REAL ≈ `9.38` → used 9+ cores effectively.

## Summary

- **Best work-unit size:** around `1000–10000` for `N = 1,000,000, k = 4`
- **Effective parallelism:** up to ~3 cores on small N, and 9+ cores on large N runs  
- **Largest N solved:** `999,999,999` with `k = 9,999,999` (batch size 99,999), running in ~30 seconds wall-clock time.
