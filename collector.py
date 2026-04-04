"""Backward-compatible entrypoint for the stock collector."""

from server.jobs.collector import *  # noqa: F401,F403


if __name__ == "__main__":
    from server.jobs.collector import main

    main()
