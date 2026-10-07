import hashlib, hmac, json, struct
def face_keys(master, i, n0):
    raw=b''.join(hmac.new(master, f"fdae-v2|face|{i}|{c}".encode(), hashlib.sha256).digest() for c in (0,1))
    def u(j):
        v=struct.unpack('>Q',raw[8*j:8*j+8])[0]
        return (v>>11)/9007199254740992.0
    m=lambda j,lo,hi: lo+u(j)*(hi-lo)
    return dict(x0=m(0,.01,.99),mu1=m(1,.05,.45),z0=m(2,.01,.99),r=m(3,3.6,4.0),y0=m(4,.01,.99),mu2=m(5,.05,.45),n0=n0)
pw="correct horse battery staple"; salt=bytes(range(16)); it=1000
master=hashlib.pbkdf2_hmac('sha256',pw.encode(),salt,it,32)
check=hmac.new(master,b"fdae-v2|check",hashlib.sha256).digest()[:8]
json.dump(dict(passphrase=pw,salt_hex=salt.hex(),iterations=it,master_hex=master.hex(),
  check_hex=check.hex(),face0=face_keys(master,0,1000),face1=face_keys(master,1,1000)),
  open('fdae_flutter/test/kdf_golden.json','w'),indent=1)
print(open('fdae_flutter/test/kdf_golden.json').read()[:400])
