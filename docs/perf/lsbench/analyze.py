import json,sys
d=sys.argv[1]
ev=[json.loads(l) for l in open(d+'/events.jsonl')]
t_init=[e['t'] for e in ev if e['kind']=='send_notification' and e.get('method')=='initialized'][0]
pubs=[e for e in ev if e['kind']=='publishDiagnostics']
target=[e for e in pubs if 'layer_diagnostics.jl' in str(e.get('uri'))]
probes=sorted([e for e in ev if e['kind']=='response' and e.get('method')=='textDocument/documentSymbol' and e['t']>t_init], key=lambda e:-e['ms'])
print('=== %s ==='%d)
print('t_initialized              : %.2f s'%t_init)
print('publishes (startup total)  : %d'%len(pubs))
print('open-file first publish    : %+.2f s after initialized'%((target[0]['t']-t_init) if target else float('nan')))
print('first publish (any file)   : %+.2f s'%(pubs[0]['t']-t_init))
print('last publish               : %+.2f s'%(pubs[-1]['t']-t_init))
print('max probe RTT post-init    : %.0f ms (at t=%.2f)'%(probes[0]['ms'],probes[0]['t']))
print('next 4 probe RTTs          : %s'%[round(p['ms'],1) for p in probes[1:5]])
print('n probes                   : %d'%len(probes))
