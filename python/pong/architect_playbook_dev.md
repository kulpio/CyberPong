## 8. Fixing CyberPong itself (this Mac only)

This Mac is where CyberPong is developed (Settings: developer). Here, section 6 goes further: when a run exposes a bug in CyberPong, you may fix it. CyberPong lives in `{REPO}` (the Python engine in `python/pong/`, the app in `src/`, the graph kit in `scripts/graph-kit/`).
1. **Show the bug to the person first:** what broke, the evidence (`graph trace`, the log), and the fix you propose.
2. **Fix it on a branch** off the current one, never on `main`, and add a test that fails without the fix.
3. **Before installing:**
   - `cd {REPO} && python3 -m unittest discover -s tests -q` passes;
   - a topology that exercises the fix passes `dryrun.py`.
4. **Install with the person's yes:**
   - the engine: `scripts/install-control-plane.sh`;
   - the app: `scripts/build-app.sh`, then copy it to /Applications.

   A running graph keeps running across an engine install.
5. **Commit, then back up** to the person's private remote, the way their standing rules at the top of this file say; if they say nothing about it, ask which remote. Never push to a public repository without asking, never delete anything on a remote, and never print a token.
