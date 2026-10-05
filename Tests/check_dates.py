"""Synthetic FAT12 date checks; no private photos or hardware required."""
from pathlib import Path
from datetime import datetime, timezone, timedelta
import hashlib
import json
import os
import struct
import subprocess
import tempfile
import time

root = Path(__file__).resolve().parents[1]
engine = root / 'Microtech USB Reader.app/Contents/Resources/Tools/recovery-engine'
work = Path(tempfile.mkdtemp(prefix='microtech-date-tests-', dir=root / 'build'))
fixture = work / 'fixture.swift'
fixture.write_text('''import Foundation
import ImageIO
import CoreGraphics
let pixels = Data([64,128,192,255])
let provider = CGDataProvider(data:pixels as CFData)!
let image = CGImage(width:1,height:1,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.noneSkipLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
let output = CGImageDestinationCreateWithURL(URL(fileURLWithPath:CommandLine.arguments[1]) as CFURL,"public.jpeg" as CFString,1,nil)!
var exif = [String:Any]()
if CommandLine.arguments.count > 2 {
    exif[kCGImagePropertyExifDateTimeOriginal as String] = CommandLine.arguments[2]
    exif["OffsetTimeOriginal"] = "+02:00"
}
CGImageDestinationAddImage(output,image,[kCGImagePropertyExifDictionary as String:exif] as CFDictionary)
precondition(CGImageDestinationFinalize(output))
''')
subprocess.run(['swiftc','-module-cache-path',str(work/'ModuleCache'),str(fixture),'-o',str(work/'fixture')],check=True)
photos = []
for index, date in enumerate(['1997:06:15 12:34:56', None, '1997:02:30 12:34:56']):
    path = work / f'fixture-{index}.jpg'
    args = [str(work/'fixture'),str(path)] + ([date] if date else [])
    subprocess.run(args,check=True)
    photos.append(path.read_bytes())

# A tiny FAT12 volume with real JPEGs and deliberately different date fields.
image = bytearray(64*512)
image[:3] = b'\xeb\x3c\x90'
struct.pack_into('<H',image,11,512)
image[13]=1
struct.pack_into('<H',image,14,1)
image[16]=1
struct.pack_into('<H',image,17,16)
struct.pack_into('<H',image,19,64)
image[21]=0xf8
struct.pack_into('<H',image,22,1)
image[510:512]=b'\x55\xaa'
image[512:515]=b'\xf8\xff\xff'

def date_word(year,month,day): return ((year-1980)<<9)|(month<<5)|day

def time_word(hour,minute,second): return (hour<<11)|(minute<<5)|(second//2)

def fat_entry(cluster,value):
    offset=512+cluster*3//2
    old=struct.unpack_from('<H',image,offset)[0]
    new=(old&0x000f)|(value<<4) if cluster%2 else (old&0xf000)|value
    struct.pack_into('<H',image,offset,new)

card_created=(date_word(1997,1,2),time_word(3,4,30),150)
card_modified=(date_word(1998,7,8),time_word(9,10,12))
invalid_created=(date_word(1997,2,30),time_word(3,4,30),0)
invalid_modified=(date_word(1997,2,30),time_word(9,10,12))
cases=[
 ('CARD',photos[0],card_created,card_modified,'card','card'),
 ('EXIF',photos[0],(0,0,0),(0,0),'photo','photo'),
 ('INVALID',photos[0],invalid_created,invalid_modified,'photo','photo'),
 ('PARTIAL',photos[0],card_created,(0,0),'card','photo'),
 ('NODATE',photos[1],(0,0,0),(0,0),'import','import'),
 ('MODONLY',photos[1],(0,0,0),card_modified,'import','card'),
 ('CREATE',photos[1],card_created,(0,0),'card','import'),
 ('BADEXIF',photos[2],invalid_created,invalid_modified,'import','import'),
 ('BADTIME',photos[0],(card_created[0],time_word(24,0,0),0),(card_modified[0],31),'photo','photo'),
]
next_cluster=2
for index,(name,content,created,modified,_,_) in enumerate(cases):
    entry=1024+index*32
    image[entry:entry+11]=name.ljust(8).encode()+b'JPG'
    image[entry+11]=0x20
    image[entry+13]=created[2]
    struct.pack_into('<HH',image,entry+14,created[1],created[0])
    struct.pack_into('<HH',image,entry+22,modified[1],modified[0])
    struct.pack_into('<H',image,entry+26,next_cluster)
    struct.pack_into('<I',image,entry+28,len(content))
    count=(len(content)+511)//512
    for c in range(next_cluster,next_cluster+count):
        fat_entry(c,c+1 if c<next_cluster+count-1 else 0xfff)
    offset=1536+(next_cluster-2)*512
    image[offset:offset+len(content)]=content
    next_cluster+=count
capture=work/'Dates.img'; capture.write_bytes(image)
output=work/'Import'/'Photos'
began=time.time()
subprocess.run([str(engine),'extract',str(capture),str(output)],check=True)
ended=time.time()
report=json.loads((output.parent/'photos-report.json').read_text())
records={Path(r['file']).stem:r for r in report['files']}
# FAT wall-clock dates use the Mac timezone; EXIF has an explicit +02:00 offset.
expected_created=datetime(1997,1,2,3,4,31,500000).timestamp()
expected_modified=datetime(1998,7,8,9,10,12).timestamp()
expected_photo=datetime(1997,6,15,12,34,56,tzinfo=timezone(timedelta(hours=2))).timestamp()
for name,content,_,_,creation_source,modification_source in cases:
    path=output/(name+'.JPG'); record=records[name]; attributes=path.stat()
    assert path.read_bytes()==content, name+' photo data changed'
    assert record['sha256']==hashlib.sha256(content).hexdigest()
    assert record['creationDateSource']==creation_source,(name,record)
    assert record['modificationDateSource']==modification_source,(name,record)
    assert 'dateWarning' not in record,record
    for actual,source,card in [(attributes.st_birthtime,creation_source,expected_created),(attributes.st_mtime,modification_source,expected_modified)]:
        if source=='import': assert began-2<=actual<=ended+2,(name,actual)
        else:
            expected=card if source=='card' else expected_photo
            assert abs(actual-expected)<0.02,(name,source,actual,expected)
assert began-2 <= output.parent.stat().st_birthtime <= ended+2
assert capture.read_bytes()==image
assert report['decodeFailures']==0
assert report['datePreservationWarnings']==0
print('PASS: card dates, creation subseconds, EXIF timezone fallback, independently missing dates, invalid calendar/time rejection, unchanged bytes, current import-folder date.')
print('Test artifacts:',work)
