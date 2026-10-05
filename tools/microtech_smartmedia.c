/* SPDX-License-Identifier: GPL-2.0-or-later
 * Read-only DPCM-USB SmartMedia acquisition.
 * Protocol and geometry from Linux sddr09.c (Robert Baruch, Andries Brouwer).
 * Preserves 512 data + 64 reader control bytes per physical NAND page.
 */
#include <libusb.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
static libusb_device_handle *h;
static unsigned char ep;
static int pagesize=512;
static int samepages(unsigned char *a,unsigned char *b,int count) {
    int meaningful=pagesize+(pagesize==256?8:16);
    for(int i=0;i<count;i++)for(int j=0;j<meaningful;j++)if(a[i*(pagesize+64)+j]!=b[i*(pagesize+64)+j]){
        fprintf(stderr,"Difference at chunk page %d, meaningful byte %d: %02x/%02x\n",i,j,a[i*(pagesize+64)+j],b[i*(pagesize+64)+j]);return 0;
    }
    return 1;
}
static int transfer_once(unsigned char *c, unsigned char *buf, int len) {
    if(c[0]!=0xed && c[0]!=0xec && c[0]!=0xe8 && c[0]!=3)return -1;
    int r=libusb_control_transfer(h,0x41,0,0,0,c,12,3000);
    if(r!=12){fprintf(stderr,"control %02x failed: %d\n",c[0],r);return -1;}
    int got=0;r=libusb_bulk_transfer(h,ep,buf,len,&got,5000);
    if(r || got!=len){fprintf(stderr,"bulk %02x failed: %s, %d/%d bytes\n",c[0],libusb_error_name(r),got,len);return -1;}
    return 0;
}
static int transfer(unsigned char *c,unsigned char *buf,int len) {
    int r=transfer_once(c,buf,len);
    if(!r || c[0]==3)return r;
    /* Recover a transient reader stall without resetting or writing the card. */
    libusb_clear_halt(h,ep);
    unsigned char sensecmd[12]={3,0x20,0,0,18},sense[18]={0};
    if(!transfer_once(sensecmd,sense,18)){
        fprintf(stderr,"Reader sense before retry: key=%02x ASC=%02x ASCQ=%02x\n",sense[2]&15,sense[12],sense[13]);
        if((sense[2]&15)==2 && sense[12]==0x3a)return -1;
    }
    libusb_clear_halt(h,ep);usleep(10000);
    memset(buf,0,len);
    return transfer_once(c,buf,len);
}
static int readpages(uint32_t page, int count, unsigned char *buf) {
    int clear=libusb_clear_halt(h,ep);if(clear)return -1;
    /* The bridge uses 256-short address units even for 256-byte NAND pages. */
    uint32_t address=page*256;
    unsigned char c[12]={0xe8,0x22,address>>24,address>>16,address>>8,address,0,0,0,0,count>>8,count};
    int r=transfer(c,buf,count*(pagesize+64));
    if(r && count>1){
        fprintf(stderr,"Retrying physical pages %u-%u one at a time.\n",page,page+count-1);
        libusb_clear_halt(h,ep);
        unsigned char sc[12]={3,0x20,0,0,18},sense[18];transfer(sc,sense,18);
        for(int i=0;i<count;i++)if(readpages(page+i,1,buf+i*(pagesize+64)))return -1;
        return 0;
    }
    return r;
}
static void hex(unsigned char *data,int n){for(int i=0;i<n;i++)printf("%02x%s",data[i],i%16==15?"\n":" ");puts("");}
int main(int argc,char **argv) {
    setbuf(stdout,NULL);
    int verify=argc==3 && !strcmp(argv[1],"--verify");
    if(argc>2 && !verify){fprintf(stderr,"Usage: %s [new-raw-output-file] | --verify raw-file\n",argv[0]);return 1;}
    libusb_context *ctx=NULL;int r=libusb_init(&ctx);if(r)return 1;
    h=libusb_open_device_with_vid_pid(ctx,0x07af,0x0006);
    if(!h){puts("Cannot open DPCM-USB");libusb_exit(ctx);return 1;}
    int claimed=0;struct libusb_config_descriptor *cfg=NULL;
    r=libusb_get_active_config_descriptor(libusb_get_device(h),&cfg);if(r)goto done;
    const struct libusb_interface_descriptor *it=&cfg->interface[0].altsetting[0];
    for(int i=0;i<it->bNumEndpoints;i++){
        const struct libusb_endpoint_descriptor *e=&it->endpoint[i];
        if((e->bmAttributes&3)==2 && (e->bEndpointAddress&0x80))ep=e->bEndpointAddress;
    }
    libusb_free_config_descriptor(cfg);
    if(!ep){r=-1;goto done;}
    r=libusb_set_configuration(h,1);printf("Configure reader: %s\n",libusb_error_name(r));if(r && r!=LIBUSB_ERROR_PIPE)goto done;
    r=libusb_claim_interface(h,0);printf("claim: %s\n",libusb_error_name(r));if(r)goto done;claimed=1;
    /* Linux DPCM initialization: reader-state queries, then clear unit attention. */
    unsigned char init[2]={0};
    for(int req=1;req<=8;req+=7){
        r=libusb_control_transfer(h,0xc1,req,0,0,init,2,3000);
        printf("Reader query %d: %d, %02x %02x\n",req,r,init[0],init[1]);
        if(r<0)puts("Reader query stalled; continuing to request sense.");
    }
    libusb_clear_halt(h,ep);
    unsigned char sensecmd[12]={3,0x20,0,0,18},sense[18]={0};
    r=transfer(sensecmd,sense,18);
    if(!r){printf("Sense: ");hex(sense,18);}else libusb_clear_halt(h,ep);
    unsigned char c[12]={0xec,0x20},data[64]={0};
    r=transfer(c,data,64);
    if(r){libusb_clear_halt(h,ep);puts("Status unavailable; attempting card identification.");}
    else printf("SmartMedia status: %02x (ready=%d, write-protected=%d)\n",data[0],!!(data[0]&0x40),!(data[0]&0x80));
    memset(c,0,12);c[0]=0xed;c[1]=0x20;
    r=transfer(c,data,64);if(r)goto done;
    printf("SmartMedia ID: ");hex(data,4);
    unsigned char manufacturer=data[0],id=data[1];int mb=0,blockpages=32;
    switch(id){case 0x6e:case 0xe8:case 0xec:mb=1;pagesize=256;blockpages=16;break;case 0x64:case 0xea:mb=2;pagesize=256;blockpages=16;break;case 0x6b:case 0xe3:case 0xe5:mb=4;blockpages=16;break;case 0xe6:mb=8;blockpages=16;break;case 0x73:mb=16;break;case 0x75:mb=32;break;case 0x76:mb=64;break;case 0x79:mb=128;break;}
    if(!mb){fprintf(stderr,"Unrecognized/unsupported NAND ID; no acquisition attempted.\n");r=-1;goto done;}
    printf("Geometry: %d MiB physical data, %d-byte pages, %d pages/block\n",mb,pagesize,blockpages);
    if(argc==2 && (!strcmp(argv[1],"--diagnose") || !strcmp(argv[1],"--diagnose-zero") || !strcmp(argv[1],"--diagnose-block"))){
        for(int mode=0;mode<4;mode++){
            uint32_t address=!strcmp(argv[1],"--diagnose-zero")?0:2*blockpages*(pagesize/2);
            unsigned char cmd[12]={0xe8,0x20|mode,address>>24,address>>16,address>>8,address,0,0,0,0,0,1};
            int count=!strcmp(argv[1],"--diagnose-block")?blockpages:1;cmd[11]=count;
            unsigned char b[18432]={0};int len=count*(mode==0?pagesize:mode==2?pagesize+64:64);
            libusb_clear_halt(h,ep);
            printf("Read mode %d, byte address %u:\n",mode,address*2);r=transfer(cmd,b,len);
            if(!r)hex(b,32);
            libusb_clear_halt(h,ep);
            if(!transfer(sensecmd,sense,18)){printf("Sense after read: ");hex(sense,18);}
        }
        r=0;goto done;
    }
    unsigned char first[18432],again[18432];
    r=readpages(blockpages,blockpages,first);if(r)goto done;
    r=readpages(blockpages,blockpages,again);if(r)goto done;
    if(!samepages(first,again,blockpages)){fprintf(stderr,"Repeated reads disagree; stopping.\n");r=-1;goto done;}
    puts("Repeated block-1 reads match. First-page control bytes:");hex(first+pagesize,16);
    r=readpages(blockpages+1,1,again);if(r)goto done;
    if(!samepages(first+pagesize+64,again,1)){
        fprintf(stderr,"Single next-page read disagrees with sequential read; stopping.\n");r=-1;goto done;
    }
    puts("Adjacent-page address matches sequential read.");
    /* Verify interleaving against the independent data-only read mode. */
    uint32_t verifyaddress=blockpages*256;
    unsigned char verifycmd[12]={0xe8,0x20,verifyaddress>>24,verifyaddress>>16,verifyaddress>>8,verifyaddress,0,0,0,0,0,blockpages};
    libusb_clear_halt(h,ep);r=transfer(verifycmd,again,blockpages*pagesize);if(r)goto done;
    for(int i=0;i<blockpages;i++)if(memcmp(first+i*(pagesize+64),again+i*pagesize,pagesize)){
        fprintf(stderr,"Data-only read disagrees with raw interleaving at page %d.\n",i);r=-1;goto done;
    }
    puts("Data-only read matches raw data for every page in test block.");
    if(argc==2 || verify){
        FILE *f=fopen(verify?argv[2]:argv[1],verify?"rb":"wbx");if(!f){perror("open raw file");r=-1;goto done;}
        uint32_t total=(uint32_t)mb*1048576/pagesize;unsigned char buf[18432],saved[18432];
        for(uint32_t page=0;page<total;page+=blockpages){
            r=readpages(page,blockpages,buf);
            if(r){fprintf(stderr,"Acquisition stopped at physical page %u; partial raw file retained.\n",page);break;}
            if(verify){
                if(fread(saved,pagesize+64,blockpages,f)!=(size_t)blockpages || !samepages(saved,buf,blockpages)){fprintf(stderr,"Verification mismatch at physical page %u.\n",page);r=-1;break;}
            }else if(fwrite(buf,pagesize+64,blockpages,f)!=(size_t)blockpages){perror("write raw output");r=-1;break;}
            if(page%(2048)==0)printf("Read %u/%u physical pages\n",page+blockpages,total);
        }
        if(verify && !r && fgetc(f)!=EOF){fprintf(stderr,"Raw file has unexpected trailing bytes.\n");r=-1;}
        int flusherr=verify?0:fflush(f),closeerr=fclose(f);
        if(flusherr || closeerr){perror("close raw output");r=-1;}
        if(!r)printf("%s: %u physical pages, %llu raw bytes; manufacturer %02x, device %02x.\n",verify?"VERIFIED":"COMPLETE",total,(unsigned long long)total*(pagesize+64),manufacturer,id);
    }
done:
    if(claimed)libusb_release_interface(h,0);
    libusb_close(h);libusb_exit(ctx);return r?1:0;
}
