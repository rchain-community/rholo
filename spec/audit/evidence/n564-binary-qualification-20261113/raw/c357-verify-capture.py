#!/usr/bin/env python3
"""Independent fail-closed capture for the stock C357 natural-trigger drill; no submissions."""
import hashlib
import json
import pathlib
import subprocess
import sys
import urllib.request
from datetime import datetime, timezone

def digest(data):
    return hashlib.sha256(data).hexdigest()

def main():
    root=pathlib.Path(sys.argv[1])
    out=root/"natural"/"independent"
    out.mkdir(parents=True,exist_ok=False)
    source=pathlib.Path("/tmp/c357-source")
    block_hash=(source/"target/n564-natural-trigger/green/inclusion-block.txt").read_text().strip()
    deploy_id=(source/"target/n564-natural-trigger/green/registry-deploy-id.txt").read_text().strip()
    assert len(block_hash)==64 and all(c in "0123456789abcdef" for c in block_hash)
    expected=(root/"runtime/rnode.sha256").read_text().split()[0]
    results=[]
    raw_blocks=[]
    blocks=[]
    for name,port in (("devnet-bootstrap",40403),("devnet-validator-1",41403)):
        node=out/name
        node.mkdir()
        hashes=subprocess.check_output(["docker","exec",name,"sha256sum","/usr/local/bin/rnode"],text=True).split()[0]
        (node/"binary.sha256").write_text(hashes+"\n")
        assert hashes==expected, (name,"binary mismatch")
        metadata=json.loads(subprocess.check_output(["docker","inspect",name],text=True))
        # Avoid retaining environment or command arguments; only the executable/image/process identity.
        instance={k:metadata[0].get(k) for k in ("Id","Image","Created")}
        instance["started_at"]=metadata[0]["State"]["StartedAt"]
        (node/"instance.json").write_text(json.dumps(instance,indent=2)+"\n")
        bodies={}
        for label,path in (("block",f"/api/v1/block/{block_hash}"),("raw-block",f"/api/block/{block_hash}/raw"),("finalized",f"/api/is-finalized/{block_hash}"),("health","/health"),("status","/api/status")):
            url=f"http://127.0.0.1:{port}{path}"
            with urllib.request.urlopen(url,timeout=10) as response:
                data=response.read()
                envelope={"observed_at_utc":datetime.now(timezone.utc).isoformat(),"status":response.status,"headers":dict(response.headers),"path":path}
                assert response.status==200
            (node/(label+".body")).write_bytes(data)
            (node/(label+".http.json")).write_text(json.dumps(envelope,indent=2)+"\n")
            bodies[label]=data
        block=json.loads(bodies["block"])
        assert block.get("blockInfo", {}).get("blockHash")==block_hash, (name,"wrong block hash")
        assert block.get("blockInfo", {}).get("preStateHash") and block.get("blockInfo", {}).get("postStateHash"), (name,"missing state identity",list(block))
        deploys=block.get("deploys")
        assert isinstance(deploys,list) and deploys, (name,"no deploy accounting")
        assert any(d.get("sig")==deploy_id or d.get("deployId")==deploy_id or d.get("signature")==deploy_id for d in deploys), (name,"registry deploy missing",deploys)
        assert all(d.get("errored") is False and isinstance(d.get("cost"),int) and d["cost"]>0 for d in deploys), (name,"incomplete accounting",deploys)
        assert json.loads(bodies["finalized"]) is True, (name,"not finalized")
        assert len(bodies["raw-block"])>100
        blocks.append(block)
        raw_blocks.append(bodies["raw-block"])
        results.append({"node":name,"binary_sha256":hashes,"block_hash":block_hash,"pre_state_hash":block["blockInfo"]["preStateHash"],"post_state_hash":block["blockInfo"]["postStateHash"],"deploys":deploys,"raw_block_sha256":digest(bodies["raw-block"]),"finalized":True})
    assert raw_blocks[0]==raw_blocks[1], "serialized block bytes differ"
    assert blocks[0]==blocks[1], "block detail differs across nodes"
    document={"aggregate":"PASS","deploy_id":deploy_id,"same_serialized_block":True,"nodes":results,"scope":"disposable two-validator network; no historical-chain compatibility or release selection"}
    (out/"verification.json").write_text(json.dumps(document,indent=2)+"\n")
    print(json.dumps(document,indent=2))

if __name__=="__main__":
    main()
