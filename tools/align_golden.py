"""Verifies the closed-form similarity transform + bilinear warp used by the
Dart aligner against skimage (what insightface uses) and cv2.warpAffine, then
writes test/align_golden.json for the Dart tests."""
import json, numpy as np, cv2
from skimage import transform as trans

ARC = np.array([[38.2946,51.6963],[73.5318,51.5014],[56.0252,71.7366],
                [41.5493,92.3655],[70.7299,92.2041]])

def sim_complex(src, dst):
    """z -> a*z + b, least squares, no reflection. Returns (ar, ai, br, bi)."""
    s = src[:,0]+1j*src[:,1]; d = dst[:,0]+1j*dst[:,1]
    sm, dm = s.mean(), d.mean()
    sc, dc = s-sm, d-dm
    a = np.sum(np.conj(sc)*dc)/np.sum(np.abs(sc)**2)
    b = dm - a*sm
    return a.real, a.imag, b.real, b.imag

def matrix(p): ar,ai,br,bi=p; return np.array([[ar,-ai,br],[ai,ar,bi]])

def warp_mirror(img, p, ow, oh):
    """dst(x,y) = bilinear(src, (dst-b)/a), constant 0 border (== cv2 default)."""
    ar,ai,br,bi = p; a = complex(ar,ai); b = complex(br,bi)
    h,w,_ = img.shape; out = np.zeros((oh,ow,3))
    for y in range(oh):
        for x in range(ow):
            z = (complex(x,y)-b)/a; sx, sy = z.real, z.imag
            x0, y0 = int(np.floor(sx)), int(np.floor(sy)); fx, fy = sx-x0, sy-y0
            def px(xx,yy): return img[yy,xx].astype(float) if 0<=xx<w and 0<=yy<h else np.zeros(3)
            out[y,x] = (px(x0,y0)*(1-fx)*(1-fy)+px(x0+1,y0)*fx*(1-fy)
                        +px(x0,y0+1)*(1-fx)*fy+px(x0+1,y0+1)*fx*fy)
    return np.floor(out+0.5).clip(0,255).astype(np.uint8)

rng = np.random.default_rng(5)
worst_m = worst_w = 0
for t in range(20):
    # plausible landmarks: ARC template under a random similarity + jitter
    ang, sc, tx, ty = rng.uniform(-.5,.5), rng.uniform(.6,2.5), rng.uniform(50,300), rng.uniform(50,300)
    R = np.array([[np.cos(ang),-np.sin(ang)],[np.sin(ang),np.cos(ang)]])
    lmk = (ARC @ R.T)*sc + [tx,ty] + rng.normal(0,1.5,ARC.shape)
    ref = trans.SimilarityTransform.from_estimate(lmk, ARC)         # same LSQ as insightface's .estimate()
    mine = matrix(sim_complex(lmk, ARC))
    worst_m = max(worst_m, np.abs(ref.params[:2]-mine).max())
print("max |skimage - closed-form| over 20 trials:", worst_m)
assert worst_m < 1e-9

img = rng.integers(0,256,(60,70,3),dtype=np.uint8)
for t in range(5):
    p = sim_complex(np.array([[20,25],[48,24],[34,38],[24,50],[46,50.]])+rng.normal(0,1,(5,2)),
                    np.array([[8,10],[22,10],[15,16],[9,22],[21,22.]]))
    M = matrix(p)
    cvw = cv2.warpAffine(img, M, (24,24), flags=cv2.INTER_LINEAR, borderValue=0)
    d = np.abs(cvw.astype(int)-warp_mirror(img,p,24,24).astype(int)); worst_w=max(worst_w,d.max())
print("NOISE image  max |cv2 - mirror| (levels):", worst_w)
assert worst_w <= 8        # cv2 quantises weights to 1/32: ~255/64 per step on pure noise
yy,xx=np.mgrid[0:60,0:70]
smooth=np.stack([(xx*3+yy)%256,(yy*3+xx*2)%200+20,(xx+yy)%256],-1).astype(np.uint8)
smooth=cv2.GaussianBlur(smooth,(0,0),3)             # face-like smoothness
worst_s=0
for t in range(5):
    p = sim_complex(np.array([[20,25],[48,24],[34,38],[24,50],[46,50.]])+rng.normal(0,1,(5,2)),
                    np.array([[8,10],[22,10],[15,16],[9,22],[21,22.]]))
    cvw = cv2.warpAffine(smooth, matrix(p), (24,24), flags=cv2.INTER_LINEAR, borderValue=0)
    worst_s=max(worst_s,np.abs(cvw.astype(int)-warp_mirror(smooth,p,24,24).astype(int)).max())
print("SMOOTH image max |cv2 - mirror| (levels):", worst_s)
assert worst_s <= 2

# golden cases for Dart
cases=[]
for t in range(2):
    src=np.array([[20,25],[48,24],[34,38],[24,50],[46,50.]])+rng.normal(0,1,(5,2))
    dst=np.array([[8,10],[22,10],[15,16],[9,22],[21,22.]])
    p=sim_complex(src,dst)
    im=rng.integers(0,256,(30,36,3),dtype=np.uint8)
    cases.append(dict(src=src.tolist(),dst=dst.tolist(),params=list(p),
        img_w=36,img_h=30,img=im.ravel().tolist(),out_w=20,out_h=18,
        out=warp_mirror(im,p,20,18).ravel().tolist()))
json.dump(cases,open('test/align_golden.json','w'))
print("wrote test/align_golden.json")
