"""Line-by-line mirror of what the Dart port does (flat bit arrays, DNA layer
collapsed to XOR), checked against the original string-based reference."""
import json, math, numpy as np
import fdae_encryption as ref

def pwlcm(x0,p,n,n0):
    def step(x):
        if x >= 0.5: x = 1.0 - x
        return x/p if x < p else (x-p)/(0.5-p)
    x=x0
    for _ in range(n0): x=step(x)
    out=[]
    for _ in range(n):
        x=step(x); out.append(x)
    return out
def logistic(x0,mu,n,n0):
    x=x0
    for _ in range(n0): x=mu*x*(1-x)
    out=[]
    for _ in range(n):
        x=mu*x*(1-x); out.append(x)
    return out
def byte(x): return int(math.floor(x*1e14))%256
def odd_stream(vals):
    ints=[byte(v) for v in vals]
    out=[]
    for bp in (7,5,3,1):
        out += [(i>>bp)&1 for i in ints]
    return out

def planes_flat(gray, lo):  # lo=0 -> planes 0..3, lo=4 -> planes 4..7
    h,w=gray.shape; out=[]
    for k in range(lo,lo+4):
        out += [int((gray[y,x]>>(7-k))&1) for y in range(h) for x in range(w)]
    return out
def recompose(high,low,h,w):
    img=np.zeros((h,w),np.uint8); hw=h*w
    seq=high+low
    for k in range(8):
        for i in range(hw):
            img[i//w,i%w] |= seq[k*hw+i]<<(7-k)
    return img

def encrypt(gray,K):
    h,w=gray.shape; mn=h*w; L=4*mn
    A1=planes_flat(gray,0); A2=planes_flat(gray,4)
    b1=odd_stream(pwlcm(K.x0,K.mu1,mn,K.n0))
    b2=odd_stream(logistic(K.z0,K.r,mn,K.n0))
    shift=sum(A2)%L
    A11=[A1[(j-shift)%L] for j in range(L)]
    B1=[0]*L
    B1[0]=A11[0]^A11[L-1]^A2[0]^b1[0]
    for i in range(1,L): B1[i]=A11[i]^A11[i-1]^A2[i]^b1[i]
    iv=A11[0]
    A22=[a^b for a,b in zip(A2,b2)]
    B11=[a^b for a,b in zip(B1,b2)]
    total=sum(B11)+sum(A22)
    s0=(K.y0+total/L)%1.0
    s=pwlcm(s0,K.mu2,2*L,K.n0)
    V=[int(math.floor(v*1e14))%L for v in s[:L]]   # 0-indexed
    W=[int(math.floor(v*1e14))%L for v in s[L:]]
    for i in range(L):
        A22[V[i]],B11[i]=B11[i],A22[V[i]]
    for j in range(L):
        A22[j],B11[W[j]]=B11[W[j]],A22[j]
    return recompose(B11,A22,h,w),iv   # high=C2(B11), low=C1(A22)

rng=np.random.default_rng(1)
for (h,w,n0) in [(5,7,50),(16,9,200),(3,3,1000)]:
    img=rng.integers(0,256,(h,w),dtype=np.uint8)
    K=ref.FdaeKeys(x0=0.612345,mu1=0.29,z0=0.234567,r=3.98,y0=0.876543,mu2=0.31,n0=n0)
    a=ref.encrypt_grayscale(img,K)
    b,iv=encrypt(img,K)
    assert np.array_equal(a.image,b) and a.iv_bit==iv, (h,w)
    assert np.array_equal(ref.decrypt_grayscale(a,K),img)
    print(f"mirror == reference for {h}x{w}, n0={n0}  (iv_bit={iv})")

# golden vectors for the Dart test
cases=[]
for (h,w,n0,seed) in [(4,6,100,11),(8,8,1000,12),(7,5,300,13)]:
    r=np.random.default_rng(seed)
    img=r.integers(0,256,(h,w),dtype=np.uint8)
    K=ref.FdaeKeys(x0=float(r.uniform(.01,.99)),mu1=float(r.uniform(.05,.45)),
                   z0=float(r.uniform(.01,.99)),r=float(r.uniform(3.6,4.0)),
                   y0=float(r.uniform(.01,.99)),mu2=float(r.uniform(.05,.45)),n0=n0)
    ct=ref.encrypt_grayscale(img,K)
    cases.append(dict(h=h,w=w,keys=K.__dict__,plain=img.ravel().tolist(),
                      cipher=ct.image.ravel().tolist(),iv_bit=ct.iv_bit))
json.dump(cases,open('fdae_flutter/test/golden.json','w'))
print("wrote golden.json with",len(cases),"cases")
