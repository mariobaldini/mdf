#!/usr/bin/env python3
"""Separate strace diagnostic: correlate native calls and timed Linux syscalls.

Tracing changes timings substantially. Never compare this report's elapsed
times with the untraced make profile benchmark or splice it into another run.
"""
import argparse
from collections import Counter
from datetime import datetime, timezone
from decimal import Decimal
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('mdf_profile', ROOT/'scripts/profile.py')
profile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profile)

# Deliberately exclude execve/execveat: -vvv can expand the environment there.
# Payload-bearing operations use raw pointers, not source/font/socket contents.
PAYLOAD = 'read,write,readv,writev,pread64,pwrite64,recvmsg,sendmsg,recvfrom,sendto'
SYSCALLS = (PAYLOAD + ',openat,openat2,close,access,faccessat,faccessat2,newfstatat,fstat,statx,readlink,readlinkat,'
            'getdents64,mmap,mprotect,munmap,madvise,brk,memfd_create,sendfile,fcntl,dup,dup2,dup3,pipe,pipe2,eventfd2,'
            'socket,socketpair,connect,shutdown,getsockopt,setsockopt,poll,ppoll,select,pselect6,epoll_wait,'
            'epoll_pwait,epoll_pwait2,futex,clock_nanosleep,nanosleep,sched_yield,clone,clone3,wait4,ioctl')
LINE = re.compile(r'^(\d+\.\d+)\s+(\w+)\((.*)\)\s+=\s+(.*?)\s+<(\d+\.\d+)>$')
FD = re.compile(r'(?<![\w])(-?\d+)<(.*?)>(?=[,\] )]|$)')


def ns(value):
    return int(Decimal(value)*1_000_000_000)


def parse_files(paths):
    """-ff files preserve TIDs; pair unfinished/resumed records if present."""
    records, incomplete, ignored = [], 0, 0
    for path in paths:
        tid = int(path.suffix[1:])
        pending, last = None, None
        for line in path.read_text(errors='replace').splitlines():
            if line.startswith(' > '):
                if last is not None:
                    last['stack'].append(line[3:].strip())
                continue
            if '<unfinished ...>' in line:
                pending = line.split('<unfinished ...>')[0]
                last = None
                continue
            if '<... ' in line and ' resumed>' in line and pending:
                line = pending + line.split(' resumed>',1)[1]
                pending = None
            match = LINE.match(line)
            if not match:
                if re.match(r'^\d+\.\d+ \w+\(',line):
                    incomplete += 1
                else:
                    ignored += 1
                last = None
                continue
            stamp, name, args, result, duration = match.groups()
            last = {'tid':tid,'epoch_ns':ns(stamp),'duration_ns':ns(duration),
                    'call':name,'arguments':args,'result':result,'stack':[]}
            records.append(last)
        if pending:
            incomplete += 1
    records.sort(key=lambda item:(item['epoch_ns'],item['tid']))
    return records, {'parsed_calls':len(records),'incomplete_calls':incomplete,'other_records':ignored}


def integer(value):
    match = re.match(r'\s*(-?0x[0-9a-fA-F]+|-?\d+)',value)
    if not match:
        return None
    value=match[1]
    return int(value,16 if 'x' in value else 10)


def annotate(records, wayland_fd):
    """Resolve descriptor lifetimes at syscall completion across CLONE_FILES threads."""
    descriptors = {0:'stdin',1:'stdout',2:'stderr'}
    completions = sorted(records,key=lambda r:r['epoch_ns']+r['duration_ns'])
    pending = iter(completions)
    next_complete = next(pending,None)

    def complete(record):
        call,args,result = record['call'],record['arguments'],record['result']
        returned=integer(result)
        if call=='close' and returned==0:
            descriptors.pop(integer(args),None)
        elif returned is not None and returned>=0:
            if call in ('openat','openat2','memfd_create'):
                label = re.search(r'"([^"\n]*)"',args)
                if label:
                    descriptors[returned]=label[1] if call!='memfd_create' else 'memfd:'+label[1]
            elif call in ('pipe','pipe2','socketpair'):
                pair=re.search(r'\[([^\]]+)\]',args)
                if pair:
                    ids=[int(x) for x in re.findall(r'(?:^|,\s*)(\d+)',pair[1])]
                    if len(ids)==2:
                        label='pipe' if call.startswith('pipe') else 'socketpair'
                        for fd in ids:descriptors[fd]=f'{label} [{ids[0]},{ids[1]}]'
            elif call in ('socket','eventfd2'):
                descriptors[returned]=call+' descriptor'
            elif call in ('dup','dup2','dup3') or (call=='fcntl' and 'F_DUPFD' in args):
                descriptors[returned]=descriptors.get(integer(args),'duplicated descriptor')
        if call=='connect' and returned==0 and integer(args)==wayland_fd:
            descriptors[wayland_fd]='Wayland compositor socket'

    for record in records:
        while next_complete and next_complete['epoch_ns']+next_complete['duration_ns'] <= record['epoch_ns']:
            complete(next_complete)
            next_complete=next(pending,None)
        labels={int(fd):label for fd,label in FD.findall(record['arguments']+' '+record['result'])}
        def is_wayland(fd):
            return fd == wayland_fd and descriptors.get(fd,'').startswith('Wayland compositor')
        # Decoded select/poll arguments supplement creation calls. They can
        # distinguish readiness on Wayland from FLTK's worker wakeup pipe.
        for fd,label in labels.items():
            if is_wayland(fd):label='Wayland compositor socket · '+label
            labels[fd]=label
        call,args,result=record['call'],record['arguments'],record['result']
        fd=integer(args)
        label=labels.get(fd,descriptors.get(fd))
        if call in ('openat','openat2','memfd_create'):
            path=re.search(r'"([^"\n]*)"',args)
            label=path[1] if path else label
        if call=='mmap':
            # mmap(..., fd, offset); earlier arguments can contain commas in
            # symbolic flags but our fd is the penultimate scalar argument.
            match=re.search(r',\s*(-?\d+)(?:<.*>)?,\s*(?:0x[0-9a-f]+|\d+)\s*$',args)
            if match:
                fd=int(match[1]);label=labels.get(fd,descriptors.get(fd)) if fd>=0 else 'anonymous memory'
        if call in ('select','pselect6','poll','ppoll','epoll_wait','epoll_pwait','epoll_pwait2'):
            # Ready descriptors are in the return annotation; a descriptor
            # merely included in the input set does not identify the waker.
            returned_labels={int(f):v for f,v in FD.findall(result)}
            ready_ids=set(returned_labels)
            if not ready_ids:
                incoming=re.search(r'\bin \[([^\]]*)\]',result)
                if incoming:ready_ids={int(v) for v in re.findall(r'(?<![\w])\d+(?![\w])',incoming[1])}
                ready_ids.update(int(v) for v in re.findall(r'fd=(\d+)(?:<.*?>)?[^}]*revents=POLLIN',result))
            ready=[('Wayland compositor socket' if is_wayland(f) else returned_labels.get(f,labels.get(f,descriptors.get(f,f'fd {f}')))) for f in sorted(ready_ids)]
            label=', '.join(ready) if ready else ('timeout' if integer(result)==0 else 'descriptor readiness; see arguments')
            nonblocking=bool(re.search(r'(?:^|,\s*)0\s*(?:\)|$)',args) if call=='poll' else
                             re.search(r'tv_sec=0,\s*tv_(?:nsec|usec)=0',args))
            record['kind']='work' if nonblocking else 'wait'
            record['label']=('Check events' if nonblocking else 'Wait for '+label)+' · '+call
        elif call=='futex':
            blocked=('FUTEX_WAIT' in args and 'EAGAIN' not in result and 'EINVAL' not in result and 'ENOSYS' not in result)
            record['kind']='wait' if blocked else 'work'
            address=args.split(',',1)[0]
            record['label']=('Wait on futex ' if blocked else 'Futex operation ')+address
            record['futex_address']=address
        else:
            record['kind']='wait' if call in ('clock_nanosleep','nanosleep','wait4') else 'work'
            record['label']=call+(' · '+label if label else '')
        record['fd']=fd
        record['descriptor']=label
        record['fd_labels']=labels
        record['description']='Observed Linux syscall elapsed time (-T): includes kernel execution, blocking, scheduling and tracing overhead; not pure CPU time or isolated disk latency.'
        if call in ('mmap','openat','read','pread64'):
            record['description']+=' Mapping/opening a file does not measure all demand-page I/O; page-fault delays can occur later outside syscalls.'
        if call=='futex':
            record['description']+=' A futex address does not identify a mutex owner. EAGAIN means the expected value changed before the wait, so that call did not sleep.'
    # Evidence only, not a fabricated dependency edge or an asserted OS owner.
    for record in records:
        if record['kind']!='wait' or record['call']!='futex':continue
        candidates=[other for other in records if other['tid']!=record['tid'] and other['call']=='futex'
                    and 'FUTEX_WAKE' in other['arguments'] and other.get('futex_address')==record['futex_address']
                    and record['epoch_ns']<=other['epoch_ns']<=record['epoch_ns']+record['duration_ns'] and (integer(other['result']) or 0)>0]
        record['related']=[f'TID {other["tid"]}: {other["call"]} {other["result"]}' for other in candidates]
        if candidates:record['description']+=' Another thread issued a successful wake at this address during the wait. This is a candidate waker, not proof of lock ownership.'


def correlate(native, records, clock_offset, started, finished):
    run=profile.include_process_launch(native,started,finished)
    ready=round(run['metrics']['first_frame_ms']*1e6)
    roles={event['thread_id']:event['track'] for event in run['events'] if event.get('thread_id')}
    main=native['process_id']
    app_events=list(run['events'])
    tracks=dict(profile.TRACKS)
    included=0
    for record in records:
        low=record['epoch_ns']-clock_offset-started
        high=low+record['duration_ns']
        low,high=max(0,low),min(ready,high)
        if high<=low:continue
        base_track=roles.get(record['tid'],f'os-{record["tid"]}')
        # A syscall can cross a native scope boundary. Split it rather than
        # assigning the complete duration to a false parent.
        candidates=[e for e in app_events if e['track'] in ({base_track,'launch'} if record['tid']==main else {base_track}) and e['kind']!='signal'
                    and e['start_ns']<high and e['start_ns']+e['duration_ns']>low]
        cuts=sorted({low,high,*(v for e in candidates for v in [e['start_ns'],e['start_ns']+e['duration_ns']] if low<v<high)})
        for begin,end in zip(cuts,cuts[1:]):
            track='launch' if record['tid']==main and end<=run['main_entry_ns'] else base_track
            tracks.setdefault(track,f'Runtime thread / TID {record["tid"]}')
            parent=max((e for e in candidates if e['track']==track and e['start_ns']<=begin and e['start_ns']+e['duration_ns']>=end),key=lambda e:e['depth'],default=None)
            run['events'].append({'name':record['label'],'track':track,'kind':record['kind'],'source':'','line':0,
                                  'function':'Linux '+record['call'],'thread_id':record['tid'],
                                  'start_ns':begin,'duration_ns':end-begin,'depth':parent['depth']+1 if parent else 0,
                                  'description':record['description'],'syscall':{**record,'original_duration_ns':record['duration_ns']}})
            included+=1
    original=profile.TRACKS
    profile.TRACKS=tracks
    try:
        run=profile.analyze_run(run)
    finally:
        profile.TRACKS=original
    # Store repeated stacks once. Synthetic own-time spans do not duplicate
    # syscall payloads, and split spans retain their complete original call.
    stacks,stack_ids=[],{}
    for event in run['self_spans']:
        event.pop('syscall',None)
    for event in run['events']:
        call=event.get('syscall')
        if not call:continue
        key=tuple(call['stack'])
        if key not in stack_ids:
            stack_ids[key]=len(stacks);stacks.append(list(key))
        event['syscall']={k:call.get(k) for k in ('call','tid','arguments','result','descriptor','original_duration_ns','related')}
        event['syscall']['stack_id']=stack_ids[key]
    run['syscall_stacks']=stacks
    return run,tracks,included


def clock_pair():
    before=time.monotonic_ns()
    real=time.time_ns()
    after=time.monotonic_ns()
    return real-(before+after)//2,(after-before)//2


def trace(binary, documents, output, cold=True, stacks=False):
    if shutil.which('strace') is None:raise RuntimeError('This separate diagnostic requires strace.')
    profile.require_wayland_session(os.environ)
    output=profile.timestamped_output(output)
    directory=output.with_suffix('')
    directory.mkdir(parents=True)
    copied=directory/'mdf'
    shutil.copy2(binary,copied)
    # A matching build-side symbol file helps libdw identify statically linked
    # FLTK functions in -k stacks; never alter the distributed executable.
    debug=ROOT/'build/fltk-ui/ReleaseFast/mdf.debug'
    if stacks and debug.is_file() and profile.elf_file(debug)['build_id']==profile.elf_file(copied)['build_id']:
        shutil.copy2(debug,directory/'mdf.debug')
        subprocess.run(['objcopy','--add-gnu-debuglink='+str(directory/'mdf.debug'),str(copied)],check=True)
    # The UI now lives in a memfd, so a filesystem debuglink cannot find its
    # private symbols. This separate -k diagnostic may embed the matching
    # unstripped engine. Regular profiling and distributed bytes stay intact.
    ui_symbols=ROOT/'build/fltk-ui/ReleaseFast/mdf-ui.unstripped.so'
    ui_payload=profile.embedded_ui(profile.elf_file(copied)) if stacks else None
    if ui_payload and ui_symbols.is_file():
        original=directory/'ui-original.so';original.write_bytes(ui_payload)
        full=profile.elf_file(ui_symbols);small=profile.elf_file(original)
        if full['build_id'] and full['build_id']==small['build_id']:
            saved=directory/'ui-with-symbols.so';shutil.copy2(ui_symbols,saved)
            pack_spec=importlib.util.spec_from_file_location('pack_frontend',ROOT/'scripts/pack-frontend.py')
            packer=importlib.util.module_from_spec(pack_spec);pack_spec.loader.exec_module(packer)
            packer.embed(copied,saved)
    collected=[]
    tracks=dict(profile.TRACKS)
    for index,document in enumerate(documents):
        prefix=directory/f'{index+1}-syscalls'
        command=['strace','-ff','-ttt','-T','-yy','-vvv','-s','0','-e','trace='+SYSCALLS,'-e','raw='+PAYLOAD]
        if stacks:command+=['-k','--stack-trace-frame-limit=12']
        command+=['-o',str(prefix),str(copied),'--profile',str(document)]
        conditions=profile.runtime_conditions()
        inputs=profile.cold_input_paths(copied,document)
        reset=profile.drop_linux_caches(flush_paths=inputs) if cold else {'success':False}
        if cold:
            reset['binary']=profile.verify_cold_binary(copied)
            reset['inputs']=profile.verify_cold_inputs(inputs[1:])
        with tempfile.TemporaryDirectory(prefix='cache-',dir=directory) as cache:
            environment={**os.environ,'XDG_CACHE_HOME':cache,'MESA_SHADER_CACHE_DISABLE':'true','__GL_SHADER_DISK_CACHE':'0','FLTK_BACKEND':'wayland'}
            environment.pop('WAYLAND_SOCKET',None)
            environment.pop('MDF_CAPTURE_FRAME',None)
            offset,error=clock_pair()
            started=time.monotonic_ns()
            process=subprocess.run(command,env=environment,capture_output=True,text=True,timeout=120)
            finished=time.monotonic_ns()
            final_offset,final_error=clock_pair()
        (directory/f'{index+1}-strace.log').write_text(process.stderr)
        if process.returncode:raise RuntimeError('Traced viewer failed: '+process.stderr.strip())
        native=json.loads(process.stdout)
        if native.get('mode')!='ReleaseFast' or native.get('ui_mode')!='Release':raise RuntimeError('Use the optimized release build for tracing.')
        if not native.get('process_id') or not any(e.get('thread_id') for e in native['events']):raise RuntimeError('Rebuild MDF: syscall correlation needs native thread IDs.')
        drift=abs(final_offset-offset)
        if drift>2_000_000:raise RuntimeError('Realtime/monotonic clock offset changed by over 2 ms; cannot correlate this trace reliably.')
        records,details=parse_files(sorted(directory.glob(f'{index+1}-syscalls.*')))
        annotate(records,native.get('wayland_fd'))
        run,extra,count=correlate(native,records,offset,started,finished)
        tracks.update(extra)
        run['cache_reset']=reset
        run['runtime_conditions']=conditions
        run['stderr']=process.stderr.strip()
        run['diagnostic']={**details,'syscall_spans':count,'clock_alignment_uncertainty_ns':drift+error+final_error+1000,
                           'stacks':stacks,'cold':cold,'calls':dict(Counter(r['call'] for r in records))}
        collected.append(profile.document_summary(document,[run]))
        print(f'Trace {document.name}: {len(records)} timed syscalls across {len({r["tid"] for r in records})} threads; timings include tracing overhead',flush=True)
    project=profile.project_context(ROOT,binary,documents[0],collected[0]['runs'][0])
    project.pop('input',None)
    archive={'generated_at':datetime.now(timezone.utc).isoformat(timespec='seconds'),'host':platform.platform(),
             'logical_cpus':os.cpu_count(),'tracks':tracks,'documents':collected,'project':project,
             'diagnostic':True,'cache_policy':'Separate strace diagnostic; '+('fsync benchmark inputs + drop_caches=3 and zero resident input pages before each launch' if cold else 'warm filesystem caches allowed by explicit --warm option'),
             'binary':str(binary),'artifacts':{'html':output.name,'text_traces':directory.name}}
    profile.write_report(archive,output)
    print('Diagnostic report:',output,flush=True)
    print('Raw timed syscall logs:',directory,flush=True)
    return archive


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary',type=Path,default=ROOT/'build/profile-trace/runtime/bin/mdf')
    parser.add_argument('--document',type=Path,action='append')
    parser.add_argument('--output',type=Path,default=ROOT/'build/profile-trace/trace.html')
    parser.add_argument('--warm',action='store_true',help='Allow warm caches for diagnosis; never a cold benchmark')
    parser.add_argument('--stacks',action='store_true',help='Also collect -k call stacks; substantially more tracing overhead')
    args=parser.parse_args()
    try:trace(args.binary.resolve(),[p.resolve() for p in (args.document or [ROOT/'SAMPLE.md',ROOT/'SAMPLE-HUGE.md'])],args.output.resolve(),not args.warm,args.stacks)
    except (OSError,RuntimeError,ValueError,subprocess.SubprocessError) as error:parser.exit(1,str(error)+'\n')


if __name__=='__main__':main()
