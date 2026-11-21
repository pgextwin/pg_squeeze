# pg_squeeze on Windows

This repository builds [pg_squeeze 1.9.6](https://github.com/Cybertec-PostgreSQL/pg_squeeze/tree/REL1_9_6)
at commit `778d170749988bdb00c1170d2dc5954540368e8b` with MSVC for
PostgreSQL 15–19 on Windows x64. The build applies a Windows compatibility
patch to the pinned upstream source.

The smoke test starts a disposable PostgreSQL cluster with logical WAL and
`shared_preload_libraries=pg_squeeze`. It creates SQL version 1.9 and runs
table, clustering-index, and TOAST squeeze cases. It then restarts the same
cluster with scheduler autostart enabled and verifies that
`squeeze.stop_worker()` stops the scheduler.

The upstream license is included in [LICENSE](LICENSE).
