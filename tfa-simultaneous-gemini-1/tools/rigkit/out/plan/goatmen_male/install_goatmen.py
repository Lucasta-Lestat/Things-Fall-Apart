"""goatmen_male installer wrapper.

    PYTHONPATH=. python tools/rigkit/out/plan/goatmen_male/install_goatmen.py <painting>

The ram horns, the ears and the skull enclose a patch of shoulder on each side. install_plan gives
those patches to the head twice over: snap_head's watershed (they lie inside its search band) and
tidy() (a small island of trunk is folded into the label around it). The shoulders inside the horn
curl then rotate with the head and draw above collars, and the head frame (largest circle inside
the head label) grows 10 %, so helmets grow with it. This wrapper leaves install_plan untouched and
puts the patches the GUIDE encloses back to trunk after each of the two steps, and undoes one-sided
leaks of the head label down the chest.

Installed with --keep-shoulder-cut: the thick horn lies over the shoulder joint, and the moved cut
(fix_shoulders) ends up wholly under the horn, so the upper arm no longer touches the trunk label
and derive_frames fails ("arm l: labels do not touch")."""
import sys

from scipy import ndimage as ndi

from tools.rigkit import install_plan as ip

_tidy, _snap = ip.tidy, ip.snap_head
MIN_PATCH = 150
BODY, FACE = ip.IDX["body"], ip.IDX["face"]


def snap_keep_horn_windows(idx, *a, **k):
    head = idx == FACE
    windows = ndi.binary_fill_holes(head) & ~head & (idx == BODY)
    windows = ndi.binary_erosion(windows, iterations=2)
    out = _snap(idx, *a, **k)
    out[windows & (out == FACE)] = BODY
    # the figure is centred and mirrored: trunk the watershed gave to the head on one side only
    # (it leaks down the chest fur below an ear) goes back to trunk
    leak = (idx == BODY) & (out == FACE) & (out[:, ::-1] == BODY)
    leak = ndi.binary_opening(leak, iterations=2)
    out[leak] = BODY
    return out


def tidy_keep_horn_windows(idx, *a, **k):
    out = _tidy(idx, *a, **k)
    lab, n = ndi.label((idx == BODY) & (out == FACE))
    for j in range(1, n + 1):                   # whole patches of shoulder only, never contour slivers
        g = lab == j
        if int(g.sum()) >= MIN_PATCH and int(ndi.binary_erosion(g, iterations=3).sum()) > 0:
            out[g] = BODY
    return out


ip.snap_head = snap_keep_horn_windows
ip.tidy = tidy_keep_horn_windows

if __name__ == "__main__":
    sys.exit(ip.main([sys.argv[1], "--race", "goatmen_male", "--variant", "tilt15",
                      "--match", "goatmen_male/default", "--keep-shoulder-cut"] + sys.argv[2:]))
