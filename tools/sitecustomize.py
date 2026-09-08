"""Work around an apycula bug that stops the rPLL being packed.

`gowin_pack` aborts with

    UnboundLocalError: cannot access local variable 'offx'

whenever nextpnr places the rPLL on the left of the die. The cause is in
apycula's GW1N_9C.get_pll_bels, which walks the four cells a PLL occupies:

    def get_pll_bels(self, bel):
        if bel.x > 27:
            offx = -1
        for off in range(4):
            yield (bel.x + offx * off, bel.y)

`offx` is only ever assigned in that one branch, so a PLL at a lower x - which
is where nextpnr puts ours - raises before yielding anything. A PLL near the
left edge has to extend to the right, so the missing branch is `offx = 1`.

This file is picked up automatically by Python's `site` module when the
directory holding it is on PYTHONPATH, so the Makefile's bitstream rule can
enable it for that one command without modifying the installed toolchain.
Nothing else in the build sets PYTHONPATH, so it applies nowhere else, and it
does nothing at all if the bug is fixed upstream or apycula is absent.
"""

try:
    from apycula import gowin_pack as _gp
except Exception:                      # not an apycula run; nothing to do
    pass
else:
    def _get_pll_bels(self, bel):
        """A PLL occupies four cells, extending away from the die edge."""
        offx = -1 if bel.x > 27 else 1
        for off in range(4):
            yield (bel.x + offx * off, bel.y)

    _target = getattr(_gp, 'GW1N_9C', None)
    if _target is not None:
        import inspect
        try:
            _buggy = 'else' not in inspect.getsource(_target.get_pll_bels)
        except (OSError, TypeError):
            _buggy = True
        if _buggy:
            _target.get_pll_bels = _get_pll_bels
