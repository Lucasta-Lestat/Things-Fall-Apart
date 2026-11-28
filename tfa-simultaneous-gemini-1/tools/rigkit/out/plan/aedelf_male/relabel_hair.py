"""aedelf_male/tilt15 label fix-up, run from the project folder right after install_plan (r3_3.png), then build_race.
The guide hair mass is wider than the painted hair and the painted face is larger than the guide face strip, so this
relabels by paint colour: violet skin under the hair label -> face (centre) or trunk/upper arm; chin -> face."""
import numpy as np, os
from PIL import Image
from scipy import ndimage as ndi
P='Rigs/races/aedelf_male/tilt15/'
body=np.asarray(Image.open(P+'body.png').convert('RGBA')).astype(int)
lab=np.asarray(Image.open(P+'labels.png').convert('RGB')).copy()
PAL={"body":(60,180,75),"face":(230,25,75),"hair":(245,130,48),"upperarm_l":(0,130,200),"upperarm_r":(70,190,255),"foot_l":(255,225,25),"foot_r":(170,180,40)}
def is_(n): return (np.abs(lab.astype(int)-np.array(PAL[n])).sum(2)<=40)
hair=is_("hair"); face=is_("face"); H,W=hair.shape
for n in ("foot_l","foot_r"):
    m=is_(n); l,k=ndi.label(m); print(n,[(int((l==i).sum()),[int(v) for v in ndi.center_of_mass(l==i)]) for i in range(1,k+1)])
fg=body[...,3]>=128
skin=ndi.binary_opening(((body[...,2]-body[...,1])>26)&fg,iterations=2)
cand=hair&ndi.binary_closing(skin,iterations=2)
fl,fn=ndi.label(face)
best=min(range(1,fn+1),key=lambda i:abs(ndi.center_of_mass(fl==i)[1]-W/2)+(1e6 if (fl==i).sum()<200 else 0))
cface=fl==best
target=fg&(is_("body")|is_("upperarm_l")|is_("upperarm_r"))
lb,n=ndi.label(cand)
ftouch=ndi.binary_dilation(cface,iterations=4); otouch=ndi.binary_dilation(target,iterations=3)
to_face=np.zeros_like(cand); to_other=np.zeros_like(cand)
for i in range(1,n+1):
    g=lb==i
    if (g&ftouch).any(): to_face|=g
    elif g.sum()>=40 and (g&otouch).any(): to_other|=g
# tidy the face: one solid blob, no leaks through the locks
nf=ndi.binary_opening(cface|to_face,iterations=3)
l,k=ndi.label(nf); nf=l==max(range(1,k+1),key=lambda i:(l==i).sum())
nf=ndi.binary_fill_holes(ndi.binary_dilation(nf,iterations=2))&(cface|to_face|hair)
leak=to_face&~nf
# chin: skin right under the face blob, labelled trunk
ys,xs=np.nonzero(nf); x0,x1=np.percentile(xs,12),np.percentile(xs,88)
down=ndi.binary_dilation(nf,structure=np.ones((3,1),bool),iterations=14)
xx=np.arange(W)[None,:]
chin=down&is_("body")&skin&(xx>=x0)&(xx<=x1)
chin=ndi.binary_opening(chin,iterations=1)
_, (iy,ix)=ndi.distance_transform_edt(~target,return_indices=True)
m=to_other|leak
lab[m]=lab[iy,ix][m]
lab[nf|chin]=PAL["face"]
print('face +',int((nf&~cface).sum()),'chin',int(chin.sum()),'to body/arm',int(m.sum()))
Image.fromarray(lab,'RGB').save(P+'labels.png',optimize=True)

# ---- second pass: dark shaded skin still labelled hair
import numpy as np, os
from PIL import Image
from scipy import ndimage as ndi
P='Rigs/races/aedelf_male/tilt15/'
body=np.asarray(Image.open(P+'body.png').convert('RGBA')).astype(int)
lab=np.asarray(Image.open(P+'labels.png').convert('RGB')).copy()
PAL={"body":(60,180,75),"face":(230,25,75),"hair":(245,130,48),"upperarm_l":(0,130,200),"upperarm_r":(70,190,255)}
def is_(n): return (np.abs(lab.astype(int)-np.array(PAL[n])).sum(2)<=40)
hair=is_("hair"); fg=body[...,3]>=128
silver=fg&(body[...,:3].max(2)>135)&((body[...,2]-body[...,1])<26)
true=ndi.binary_opening(ndi.binary_closing(silver,iterations=4),iterations=2)
true=ndi.binary_dilation(true,iterations=2)   # keep the hair's own dark contour
left=hair&~true
target=fg&(is_("body")|is_("upperarm_l")|is_("upperarm_r"))
otouch=ndi.binary_dilation(target,iterations=3)
lb,n=ndi.label(left); m=np.zeros_like(left)
for i in range(1,n+1):
    g=lb==i
    if g.sum()>=40 and (g&otouch).any(): m|=g
_, (iy,ix)=ndi.distance_transform_edt(~target,return_indices=True)
lab[m]=lab[iy,ix][m]
print('more to body/arm',int(m.sum()))
Image.fromarray(lab,'RGB').save(P+'labels.png',optimize=True)
