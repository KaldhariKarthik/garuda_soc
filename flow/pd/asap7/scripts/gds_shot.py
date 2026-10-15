# =============================================================================
# gds_shot.py -- KLayout batch render of a GDS to a PNG.
#
#   klayout -zz -rd gds=<file> -rd lyp=<layer props> -rd out=<png> \
#           [-rd keep=30,40,50] [-rd size=2000x1875] -r gds_shot.py
#
# keep: GDS layer numbers to show (ASAP7: M1=19 M2=20 M3=30 M4=40 M5=50
# M6=60 M7=70); every other layer is hidden. Without it, all layers show.
# run_gds_shot.sh is the wrapper.
# =============================================================================
import pya


def _arg(name, default=None):
    # klayout -rd name=value defines a global; a missing one is a NameError.
    return globals().get(name, default)


gds = _arg("gds")
out = _arg("out")
lyp = _arg("lyp", "")
keep = _arg("keep", "")
size = _arg("size", "2000x1875")
if not gds or not out:
    raise SystemExit("gds_shot.py: -rd gds=<file> and -rd out=<png> are required")
w, h = (int(x) for x in size.lower().split("x"))

v = pya.LayoutView()
v.set_config("background-color", "#000000")
v.set_config("grid-visible", "false")
v.set_config("text-visible", "false")
v.load_layout(gds, 0)
if lyp:
    v.load_layer_props(lyp)

keep_set = set(int(x) for x in keep.split(",") if x.strip()) if keep else None
if keep_set is not None:
    it = v.begin_layers()
    while not it.at_end():
        lp = it.current()
        lp.visible = lp.source_layer in keep_set
        v.set_layer_properties(it, lp)
        it.next()

v.max_hier()
v.zoom_fit()
v.save_image_with_options(out, w, h, 0, 0, 0, pya.DBox(), False)
print("wrote", out)
