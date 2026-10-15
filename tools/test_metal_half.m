// GPU regression for the emitted half helpers. Build with `make build/test_metal_half`.
#import <Metal/Metal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "../runtime/nvn/maxwell/shader.h"
// Exercise the translated probe, including an unvisited PC, in a real fragment pipeline.
static int check_probe(id<MTLDevice> dev, const char *scale, const char *offset, unsigned pc, float expected) {
    uint64_t blob[0x98 / 8] = {0};
    ((uint32_t *)blob)[0x78 / 4] = 0xf;
    blob[0x88 / 8] = 0x010000000007f000ull | ((uint64_t)0xbe800000u << 20); // MOV32I r0, -0.25
    blob[0x90 / 8] = 0xe30000000007000full; // EXIT
    setenv("LARECOMP_DBG_SCALE", scale, 1);
    setenv("LARECOMP_DBG_OFFSET", offset, 1);
    maxwell_dbg_code = (uint8_t *)blob; maxwell_dbg_pc = pc; maxwell_dbg_reg = 0;
    ShaderKey key = {0};
    ShaderInfo *si = maxwell_translate((uint8_t *)blob, sizeof blob, STAGE_FRAGMENT, &key);
    maxwell_dbg_code = NULL;
    if (!si->msl) { fprintf(stderr, "%s\n", si->error); maxwell_free(si); return 1; }
    NSString *source = [@(si->msl) stringByAppendingString:
        @"\nvertex float4 probe_vertex(uint i [[vertex_id]]) { float2 p[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)}; return float4(p[i],0,1); }\n"];
    NSError *error = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:source options:nil error:&error];
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"probe_vertex"];
    pd.fragmentFunction = [lib newFunctionWithName:@"main0"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
    id<MTLRenderPipelineState> pipe = lib ? [dev newRenderPipelineStateWithDescriptor:pd error:&error] : nil;
    if (!pipe) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); maxwell_free(si); return 1; }
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:2 height:2 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModeShared;
    id<MTLTexture> tex = [dev newTextureWithDescriptor:td];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = tex;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
    [enc setRenderPipelineState:pipe];
    float tint[8] = {0}; [enc setFragmentBytes:tint length:sizeof tint atIndex:19];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
    if (cb.error) { fprintf(stderr, "%s\n", cb.error.localizedDescription.UTF8String); maxwell_free(si); return 1; }
    float pixels[16];
    [tex getBytes:pixels bytesPerRow:8*sizeof(float) fromRegion:MTLRegionMake2D(0,0,2,2) mipmapLevel:0];
    int bad = 0;
    for (int i=0;i<4;i++)
        if (pixels[4*i] != expected || pixels[4*i+1] != expected || pixels[4*i+2] != expected || pixels[4*i+3] != 1.0f) bad++;
    if (bad) fprintf(stderr, "probe scale=%s offset=%s pc=%x: got %g expected %g\n", scale, offset, pc, pixels[0], expected);
    maxwell_free(si); return bad;
}

int main(void) { @autoreleasepool {
    uint64_t code[] = {0, 0xe30000000007000full};
    ShaderKey key = {0};
    ShaderInfo *si = maxwell_translate((uint8_t *)code, sizeof code, STAGE_COMPUTE, &key);
    if (!si->msl) { fprintf(stderr, "%s\n", si->error); return 1; }
    const char *beg = strstr(si->msl, "static inline float h2f");
    if (!beg) { fprintf(stderr, "missing half helpers\n"); return 1; }
    const char *end = strstr(beg, "static inline uint prmt");
    NSString *helper = [[NSString alloc] initWithBytes:beg length:end-beg encoding:NSUTF8StringEncoding];
    NSString *source = [@"#include <metal_stdlib>\nusing namespace metal;\n" stringByAppendingString:helper];
    source = [source stringByAppendingString:@"kernel void check(device uint4 *out [[buffer(0)]], uint i [[thread_position_in_grid]]) { uint v = i | ((65535u - i) << 16); float2 h = hx(v, 0u); out[i] = uint4(as_type<uint>(h.x), as_type<uint>(h.y), hpack(h, 0u, 0u), as_type<uint>(h.x * h.x)); }\n"];
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) { fprintf(stderr, "Metal device unavailable (GPU access is required)\n"); return 1; }
    NSError *error = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:source options:nil error:&error];
    id<MTLComputePipelineState> pipe = lib ? [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"check"] error:&error] : nil;
    if (!pipe) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
    id<MTLBuffer> out = [dev newBufferWithLength:65536*16 options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> q = [dev newCommandQueue]; id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder]; [enc setComputePipelineState:pipe]; [enc setBuffer:out offset:0 atIndex:0];
    [enc dispatchThreads:MTLSizeMake(65536,1,1) threadsPerThreadgroup:MTLSizeMake(64,1,1)]; [enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
    if (cb.error) { fprintf(stderr, "%s\n", cb.error.localizedDescription.UTF8String); return 1; }
    uint32_t *got = out.contents; int bad=0;
    for (unsigned i=0;i<65536;i++) {
        uint16_t lo=i, hi=65535-i; _Float16 hl, hh; memcpy(&hl,&lo,2); memcpy(&hh,&hi,2);
        float fl=hl, fh=hh, square=fl*fl; uint32_t bl,bh,bs; memcpy(&bl,&fl,4); memcpy(&bh,&fh,4); memcpy(&bs,&square,4);
        int nanlo=(lo&0x7c00)==0x7c00 && (lo&0x3ff), nanhi=(hi&0x7c00)==0x7c00 && (hi&0x3ff);
        if ((nanlo && (got[4*i] & 0x7fffffff) <= 0x7f800000) || (nanhi && (got[4*i+1] & 0x7fffffff) <= 0x7f800000) || (!nanlo && (got[4*i]!=bl || got[4*i+3]!=bs)) || (!nanhi && got[4*i+1]!=bh) || (!nanlo && !nanhi && got[4*i+2]!=(lo|((uint32_t)hi<<16)))) { if (bad++<5) printf("mismatch %04x: %08x/%08x\n",i,got[4*i],bl); }
    }
    printf("%s: all 65536 half encodings, paired lanes, finite round trips: %d failures\n",dev.name.UTF8String,bad);
    maxwell_free(si);
    bad += check_probe(dev, "1", "0", 8, -0.25f);
    bad += check_probe(dev, "1", "0.5", 8, 0.25f);
    bad += check_probe(dev, "-1", "0.5", 8, 0.75f);
    bad += check_probe(dev, "0", "0.5", 8, 0.5f);
    bad += check_probe(dev, "-1", "0.5", 16, -1.0f);
    unsetenv("LARECOMP_DBG_SCALE"); unsetenv("LARECOMP_DBG_OFFSET");
    printf("half/probe GPU checks: %d total failures\n", bad);
    return bad != 0;
} }
