import re,json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]

def scan(text):
    found=[]
    def quoted(i):
        start=i;i+=1;parts=[];args=[];part=''
        while i<len(text):
            if text[i]=='"':
                parts.append(part)
                found.append((start,i+1,''.join(p+('%@' if n<len(args) else '') for n,p in enumerate(parts)),args))
                return i+1
            if text[i]=='\\':
                if text[i+1:i+2]=='(':
                    parts.append(part);part='';a=i+2;i=a;level=1
                    while level:
                        if text[i]=='"':i=quoted(i);continue
                        if text[i]=='(':level+=1
                        if text[i]==')':level-=1
                        i+=1
                    args.append(text[a:i-1]);continue
                esc=text[i+1];part+= {'n':'\n','r':'\r','t':'\t','"':'"','\\':'\\'}.get(esc,'\\'+esc);i+=2;continue
            part+=text[i];i+=1
        raise ValueError('unterminated string')
    i=0
    while i<len(text):
        if text[i:i+2]=='//':
            i=text.find('\n',i);i=len(text) if i<0 else i
        elif text[i:i+2]=='/*':
            i=text.find('*/',i+2)+2
        elif text[i]=='"':i=quoted(i)
        else:i+=1
    return found

def inventory():
    keys={}
    for folder in ['Cam','CamCapture','CamControls','Shared']:
        for p in (ROOT/folder).glob('*.swift'):
            if p.name in ['DebugFixtures.swift','Localization.swift']:continue
            for start,end,key,args in scan(p.read_text()):
                if re.search('[\u4e00-\u9fff]',key):
                    keys.setdefault(key,[]).append(str(p.relative_to(ROOT))+':'+str(p.read_text()[:start].count('\n')+1))
    return keys
if __name__=='__main__':
    keys=inventory();(ROOT/'artifacts/v30-localization/inventory.json').write_text(json.dumps(keys,ensure_ascii=False,indent=2))
    print('COUNT',len(keys))
    for n,(k,v) in enumerate(keys.items()): print(f'{n}\t{k!r}\t{v[0]}')
