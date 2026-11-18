# pg_squeeze on Windows

This repository builds [pg_squeeze 1.9.4](https://github.com/Cybertec-PostgreSQL/pg_squeeze/tree/REL1_9_4)
at commit `400c5f6ae9bc911073a6824e9a19f4d475fb7331` with MSVC for
PostgreSQL 15–18 on Windows x64. The build applies a Windows compatibility
patch to the pinned upstream source.

The smoke test starts a disposable PostgreSQL cluster with logical WAL and
`shared_preload_libraries=pg_squeeze`. It creates SQL version 1.9 and runs
table, clustering-index, and TOAST squeeze cases. It then restarts the same
cluster with scheduler autostart enabled and verifies that
`squeeze.stop_worker()` stops the scheduler.

The upstream license is included in [LICENSE](LICENSE).
