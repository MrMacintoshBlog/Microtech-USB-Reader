/* Read-only DPCM-USB probe. Commands follow Linux usb-storage CB protocol. */
#include <libusb.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
static libusb_device_handle *h;
static unsigned char ep;
static int command(unsigned char op, int n, unsigned char *out) {
    unsigned char c[12]={0}; c[0]=op;
    if(op==0x12 || op==0x03) c[4]=n;
    int r=libusb_control_transfer(h,0x21,0,0,0,c,12,3000);
    printf("command %02x: %d\n",op,r);
    if(r<0)return r;
    int got=0; r=libusb_bulk_transfer(h,ep,out,n,&got,3000);
    printf("read: %s (%d bytes)\n",libusb_error_name(r),got);
    if(r<0)return r;
    for(int i=0;i<got;i++)printf("%02x%s",out[i],(i%16==15)?"\n":" ");
    puts(""); return got;
}
int main(int argc, char **argv) {
    setbuf(stdout,NULL);
    int verify=argc==3 && !strcmp(argv[1],"--verify");
    if(argc>2 && !verify){fprintf(stderr,"Usage: %s [new-image] | --verify image\n",argv[0]);return 1;}
    libusb_context *ctx=NULL; int r=libusb_init(&ctx); if(r)return 1;
    h=libusb_open_device_with_vid_pid(ctx,0x07af,0x0006);
    if(!h){puts("Cannot open DPCM-USB");libusb_exit(ctx);return 1;}
    struct libusb_config_descriptor *cfg=NULL;
    r=libusb_get_active_config_descriptor(libusb_get_device(h),&cfg);
    if(r)goto done;
    const struct libusb_interface_descriptor *it=&cfg->interface[0].altsetting[0];
    for(int i=0;i<it->bNumEndpoints;i++){
        const struct libusb_endpoint_descriptor *e=&it->endpoint[i];
        printf("endpoint %02x type %d maxpacket %d\n",e->bEndpointAddress,e->bmAttributes&3,e->wMaxPacketSize);
        if((e->bmAttributes&3)==2 && (e->bEndpointAddress&0x80))ep=e->bEndpointAddress;
    }
    libusb_free_config_descriptor(cfg);
    r=libusb_claim_interface(h,0);printf("claim: %s\n",libusb_error_name(r));
    if(r)goto done;
    unsigned char data[64]={0};
    r=command(0x12,36,data);if(r<0)goto release;
    if(r>=36)printf("INQUIRY: %.8s %.16s %.4s\n",data+8,data+16,data+32);
    memset(data,0,sizeof data);r=command(0x25,8,data);
    if(r==8){unsigned long long last=0,size=0;for(int i=0;i<4;i++){last=(last<<8)|data[i];size=(size<<8)|data[i+4];}printf("Capacity: %llu bytes; sector size %llu\n",(last+1)*size,size);
        if((argc==2 || verify) && size==512 && last<0xffffffff){
            FILE *f=fopen(verify?argv[2]:argv[1],verify?"rb":"wbx");if(!f){perror("open image");r=-1;}else{
                unsigned char buf[32768],saved[32768];
                for(uint32_t lba=0;lba<=last;){
                    unsigned int count=(last+1-lba)>64?64:(unsigned int)(last+1-lba);
                    unsigned char c[12]={0x28,0,(lba>>24)&255,(lba>>16)&255,(lba>>8)&255,lba&255,0,0,count,0,0,0};
                    r=libusb_control_transfer(h,0x21,0,0,0,c,12,3000);
                    if(r!=12){fprintf(stderr,"Command failed at sector %u: %d\n",lba,r);r=-1;break;}
                    int got=0;r=libusb_bulk_transfer(h,ep,buf,count*512,&got,5000);
                    if(r || got!=(int)(count*512)){fprintf(stderr,"Read failed at sector %u: %d, %d bytes\n",lba,r,got);r=-1;break;}
                    if(verify){if(fread(saved,512,count,f)!=count || memcmp(saved,buf,count*512)){fprintf(stderr,"Verification mismatch at sector %u\n",lba);r=-1;break;}}
                    else if(fwrite(buf,512,count,f)!=count){perror("write image");r=-1;break;}
                    lba+=count;
                    if(lba%2048==0 || lba>last)printf("Read %u/%llu sectors\n",lba,last+1);
                }
                if(verify && r>=0 && fgetc(f)!=EOF){fprintf(stderr,"Unexpected trailing bytes in image\n");r=-1;}
                if(fclose(f)){perror("close image");r=-1;}
                if(r>=0)puts(verify?"VERIFIED: Full CompactFlash image matches card.":"COMPLETE: Full CompactFlash image completed.");
            }
        }else if(argc>1){fprintf(stderr,"Unsupported CompactFlash geometry\n");r=-1;}
    }
    else {fprintf(stderr,"Cannot read card capacity\n");r=-1;}
release:
    libusb_release_interface(h,0);
done:
    libusb_close(h);libusb_exit(ctx);return r<0?1:0;
}
