#include <optix.h>

#include "structs.hh"
#include "random.h"

#include <sutil/vec_math.h>
#include <cuda/helpers.h>

static __forceinline__ __device__ void* unpackPointer( unsigned int i0, unsigned int i1 )
{
    const unsigned long long uptr = static_cast<unsigned long long>( i0 ) << 32 | i1;
    void*           ptr = reinterpret_cast<void*>( uptr );
    return ptr;
}


static __forceinline__ __device__ void  packPointer( void* ptr, unsigned int& i0, unsigned int& i1 )
{
    const unsigned long long uptr = reinterpret_cast<unsigned long long>( ptr );
    i0 = uptr >> 32;
    i1 = uptr & 0x00000000ffffffff;
}

/***** SHADER *****/

extern "C" {
__constant__ Params params;
}

struct Intersection
{
  Material material;
  float3 normal;
  float3 xyz;
  float3 mask_color  = make_float3(1.0f);
  float3 accum_color = make_float3(0.0f);
  bool hit = false;
  bool done = false;
  unsigned int seed;
};

extern "C" __device__ float rng(unsigned int &seed) {
  return rnd(seed) * 2.0f - 1.0f;
}

extern "C" __device__ float3 shoot_ray_hemisphere(Intersection* intersection) {
  float3 random_dir = make_float3(rng(intersection->seed),
                                  rng(intersection->seed),
                                  rng(intersection->seed));
  
  return normalize(faceforward(random_dir, intersection->normal, random_dir));
}

static __forceinline__ __device__ Intersection* getInter()
{
    const unsigned int u0 = optixGetPayload_0();
    const unsigned int u1 = optixGetPayload_1();
    return reinterpret_cast<Intersection*>(unpackPointer(u0, u1));
}


/**** TRACE FUNCTIONS ****/

static __forceinline__ __device__ void trace_occlusion(OptixTraversableHandle handle,
                                                      float3 ray_origin,
                                                      float3 ray_direction,
                                                      float  tmin,
                                                      float  tmax,
                                                      Intersection* inter)
{
    unsigned int u0, u1;
    packPointer(inter, u0, u1);
    optixTrace(handle,
              ray_origin,
              ray_direction,
              tmin,
              tmax,
              0.0f,                    // rayTime
              OptixVisibilityMask(1),
              OPTIX_RAY_FLAG_TERMINATE_ON_FIRST_HIT,
              RAY_TYPE_OCCLUSION,      // SBT offset
              RAY_TYPE_COUNT,          // SBT stride
              RAY_TYPE_OCCLUSION,      // missSBTIndex
              u0, u1);
}


static __forceinline__ __device__ void trace_radiance(OptixTraversableHandle handle,
                                                      float3 ray_origin,
                                                      float3 ray_direction,
                                                      float  tmin,
                                                      float  tmax,
                                                      Intersection* inter)
{
    unsigned int u0, u1;
    packPointer(inter, u0, u1);
    optixTrace(handle,
              ray_origin,
              ray_direction,
              tmin,
              tmax,
              0.0f,                // rayTime
              OptixVisibilityMask(1),
              OPTIX_RAY_FLAG_NONE,
              RAY_TYPE_RADIANCE,        // SBT offset
              RAY_TYPE_COUNT,           // SBT stride
              RAY_TYPE_RADIANCE,        // missSBTIndex
              u0, u1);
}

extern "C" __device__ void print_color(float3 color) {
  printf("Color: %f %f %f\n", color.x, color.y, color.z);
}


extern "C" __global__ void __raygen__rg() {
  const float2 size = make_float2(params.width, params.height);
  const float3 eye  = params.eye;
  const float3 U    = params.U;
  const float3 V    = params.V;
  const float3 W    = params.W;
  const uint3  idx  = optixGetLaunchIndex();
  const float2  idx2 = make_float2(idx.x, idx.y);

  const int subframe_index = params.subframe_index;
  unsigned int seed        = tea<4>(idx.y*size.x + idx.x, subframe_index);

  const int samples_per_launch = params.samples_per_launch;
  const int nb_bounces = 3;

  float3 accum_color = make_float3(0.0f);

  for (int i = 0; i < samples_per_launch; i++) {
    Intersection intersection;
    intersection.seed        = seed;

    /* Builds ray direction/origin */
    const float2 antialiasing_jitter = make_float2(rng(seed), rng(seed));
    const float3 d                   = make_float3((2.0f * idx2 + antialiasing_jitter) / size - 1.0f, 1.0f);
    float3 ray_direction             = normalize(d.x*U + d.y*V + W);
    float3 ray_origin                = eye;

    for (int j = 0; j < nb_bounces; j++) {
      intersection.done = false;

      trace_radiance(params.handle,
                    ray_origin,
                    ray_direction,
                    0.01f,
                    1e16f,
                    &intersection);

      if (intersection.done) break;

      ray_origin    = intersection.xyz;
      ray_direction = shoot_ray_hemisphere(&intersection);
    }
    accum_color += intersection.accum_color;
  }
  const uint3 launch_index       = optixGetLaunchIndex();
  const unsigned int image_index = launch_index.y * params.width + launch_index.x;
  accum_color                    = accum_color / static_cast<float>(samples_per_launch);

  if( subframe_index > 0 ) {
      const float a                  = 1.0f / static_cast<float>(subframe_index + 1);
      const float3 accum_color_prev = make_float3(params.accum_buffer[image_index]);
      accum_color = lerp(accum_color_prev, accum_color, a);
  }
  params.accum_buffer[ image_index ] = make_float4(accum_color, 1.0f);
  params.frame_buffer[ image_index ] = make_color (accum_color);
}


/**** OCCLUSION ****/

extern "C" __global__ void __miss__occlusion() {
  Intersection* intersection = getInter();
  intersection->hit = false;
}

extern "C" __global__ void __closesthit__occlusion() {
  HitGroupData* rt_data = reinterpret_cast<HitGroupData*>(optixGetSbtDataPointer());
  if (rt_data->material.emit) {
    Intersection* intersection = getInter();
    intersection->material = rt_data->material;
    intersection->hit = true;
  }
}


/**** RADIANCE ****/

extern "C" __global__ void __miss__radiance() {
    MissData* rt_data  = reinterpret_cast<MissData*>(optixGetSbtDataPointer());
    Intersection* intersection = getInter();

    intersection->done        = true;
    intersection->accum_color += make_float3(rt_data->bg_color) * intersection->mask_color;
}

extern "C" __device__ float3 shoot_ray_to_light(Intersection* intersection) {
  const unsigned int count = 7u;
  for (int i = 0; i < count; i++) {
    float3 dir = shoot_ray_hemisphere(intersection);

    trace_occlusion(params.handle, intersection->xyz, dir, 0.01f, 1e16f, intersection);

    if (intersection->hit) {
      const float d = clamp(dot(intersection->normal, dir), 0.0f, 1.0f);
      return d * intersection->material.emission_color;
    }
  }
  return make_float3(0.0f);
}

extern "C" __device__ float3 barycentric_normal(Intersection* intersection, const float3 v1, const float3 v2, const float3 v3) {
  const float3 edge1 = v2 - v1;
  const float3 edge2 = v3 - v1;
  const float3 i = intersection->xyz - v1;
  const float d00 = dot(edge1, edge1);
  const float d01 = dot(edge1, edge2);
  const float d11 = dot(edge2,edge2);
  const float d20 = dot(i, edge1);
  const float d21 = dot(i, edge2);
  const float denom = d00 * d11 - d01 * d01;

  const float v = (d11 * d20 - d01 * d21) / denom;
  const float w = (d00 * d21 - d01 * d20) / denom; 
  const float u = 1 - v - w;

  return intersection->normal * (v + w + u);
}

extern "C" __global__ void __closesthit__radiance() {

  HitGroupData* rt_data = reinterpret_cast<HitGroupData*>(optixGetSbtDataPointer());
  Intersection* intersection = getInter();
  
  if (rt_data->material.emit) {
    intersection->accum_color += rt_data->material.emission_color * intersection->mask_color;
    intersection->done = true;
  } else {
    intersection->mask_color *= rt_data->material.diffuse_color;

    const int    prim_idx        = optixGetPrimitiveIndex();
    const float3 ray_dir         = optixGetWorldRayDirection();
    const int    vert_idx_offset = prim_idx*3;

    const float3 v1      = make_float3(rt_data->vertices[vert_idx_offset + 0]);
    const float3 v2      = make_float3(rt_data->vertices[vert_idx_offset + 1]);
    const float3 v3      = make_float3(rt_data->vertices[vert_idx_offset + 2]);
    float3 N_0           = normalize(cross(v2-v1, v3-v1));
    intersection->normal = faceforward(N_0, -ray_dir, N_0);
    intersection->xyz    = optixGetWorldRayOrigin() + optixGetRayTmax() * ray_dir;
    intersection->normal = barycentric_normal(intersection, v1, v2, v3);

    intersection->accum_color += shoot_ray_to_light(intersection) * intersection->mask_color;
  }
}