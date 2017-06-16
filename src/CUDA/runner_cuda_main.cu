
#include "runner_cuda_main.h"
#include "queue_cuda.h"
#include "task_cuda.h"
#include "../kernel_hydro.h"
#include "../dimension.h"

/*Definition of particle structures (SoA on GPU) */
struct particle_arrays{
/* Device array containing the particle ID */
__device__ long long int *id;
/*Device array containing the particle positions. */
__device__ double *x_x, *x_y, *x_z;
/*Device array containing the particle predicted velocity */
__device__ float3 *v;
/*Device array containing the particle acceleration. */
__device__ float3 *a_hydro;
/* Device array contining the particle cutoff radius */
__device__ float *h;
/* Device array containing particle masses */
__device__ float *mass;
/* Device array containing particle densities. */
__device__ float *rho;
/* Device array containing the particle entropies. */
__device__ float *entropy;

/* Unclear if unions work on the GPU, so unrolling the union for now */
/* DENSITY */
/* Device array containing the number of neighbours. */
__device__ float *wcount;
/* Device array containing the number of neighbours spatial derivative */
__device__ float *wcount_dh;
/* Device array containing the derative of the density w.r.t. h */
__device__ float *rho_dh;
/* Device array containing the particle velocity curl. */
__device__ float3 *rot_v;
/* Device array containing the particle velocity divergence */
__device__ float *div_v;

/* FLOAT */
/* Device array containing the balsara switch */
__device__ float *balsara;
/* Device array containing the "Grad h" term */
__device__ float f;
/* Device array containing the pressure over density squared */
__device__ float *P_over_rho2;
/* Device array containing the particle sound speeds */
__device__ float *soundspeed;
/* Device array containing the signal velocities */
__device__ float *v_sig;
/* Device array containing the time derivative of the smoothing lengths */
__device__ float *h_dt;

/* Device array containing time step length */
__device__ timebin_t *time_bin;
};

__device__ struct particle_arrays cuda_parts;
__constant__ int cuda_nr_parts;

/* Cell array and array of CPU cell pointers.*/
__device__ struct cell_cuda *cells;
__device__ struct cell *cpu_cells;

/* Queue variables*/
__device__ struct queue_cuda cuda_queues[ cuda_numqueues ];
__device__ struct load_queue;
__device__ struct unload_queue;

/* Array of tasks on the device */
__device__ struct task_cuda *tasks;

/* Array of cuda tasks on the host */
struct task_cuda *tasks_host;

/* Array of unlocks on the device*/
__device__ int *cuda_unlocks;

/* Array of unlocks on the host. */
int *host_unlocks;

/* Simulation constants */
__device__ __constant__ integertime_t ti_current;
__device__ __constant__ double dim[3];
__device__ __constant__ timebin_t max_active_bin;

/* Density kernel function */
__constant__ cuda_kernel_coeffs[(kernel_degree+1)*(kernel_ivals+1)];

__device__ int cuda_cell_is_active( struct cell_cuda *c ) {
  return (c->ti_end_min == e->ti_current);
}

__device__ float cuda_pow_dimension( float x ) {

#if defined(HYDRO_DIMENSION_3D)
  return x*x*x;
#elif defined(HYDRO_DIMENSION_2D)
  return x*x;
#elif defined(HYDRO_DIMENSION_3D)
  return x;
#else
  printf("The dimension is not defined!");
  return 0.f;
#endif
}

__device__ float cuda_pow_dimension_plus_one( float x ) {
#if defined(HYDRO_DIMENSION_3D)
  const float x2 = x*x;
  return x2*x2;
#elif defined(HYDRO_DIMENSION_2D)
  return x*x*x;
#elif defined(HYDRO_DIMENSION_3D)
  return x*x;
#else
  printf("The dimension is not defined!");
  return 0.f;
#endif
}

__device__ __inline__ int  cuda_part_is_active( int pid ) {

  return ( cuda_parts.part_bin[pid]  <= max_active_bin );
}


__device__ void load_cell(int cell_index)
{
  /* Get the pointer to the relevant cells. */
  struct cell *cpu_cell = &cpu_cells[cell_index];
  struct cell *cell = &cells[cell_index];
  struct part *parts = cpu_cell->parts;
  int i;
  /* Get the index to copy the data for the 0th particle in this cell to.*/
  int start = cell->first_part;

  for( i = threadIdx.x; i < cell->part_count; i+= blockDim.x ){
    struct part *current = &parts[i];
    /* Load the ID and position*/
    long long local_id = current->id;
    double local_x[3];
    local_x[0] = current->x[0];
    local_x[1] = current->x[1];
    local_x[2] = current->x[2];

    /* Unpack the ID and position and put into the device arrays. */
    cuda_parts.id[start+i] = local_id;
    cuda_parts.x_x[start+i] = local_x[0];
    cuda_parts.x_y[start+i] = local_x[1];
    cuda_parts.x_z[start+i] = local_x[2];

    /* Load the predicted velocity */ 
    float local_tempv[3];
    local_tempv[0] = current->v[0];
    local_tempv[1] = current->v[1];
    local_tempv[2] = current->v[2];

    /* Repack the predicted velocity */
    float3 local_v;
    local_v.x = local_tempv[0];
    local_v.y = local_tempv[1];
    local_v.z = local_tempv[2];

    /* Copy the predicted velocity to the particle array. */
    cuda_parts.v[start+i] = local_v;
   
    /* Load the acceleration */ 
    float local_tempa[3];
    local_tempa[0] = current->a_hydro[0];
    local_tempa[1] = current->a_hydro[1];
    local_tempa[2] = current->a_hydro[2];

    /* Repack the acceleration */
    float3 local_a;
    local_a.x = local_tempa[0];
    local_a.y = local_tempa[1];
    local_a.z = local_tempa[2];

    /* Copy the predicted velocity to the particle array. */
    cuda_parts.a_hydro[start+i] = local_a;

    /* Copy the cutoff, mass, density, entropy and entropy derivative*/
    float local_h, local_mass, local_rho, local_entropy, local_entropy_dt;
    local_h = current->h;
    local_mass = current->mass;
    local_rho = current->rho;
    local_entropy = current->entropy;
    local_entropy_dt = current->entropy_dt;

    cuda_parts.h[start+i] = local_h;
    cuda_parts.mass[start+i] = local_mass;
    cuda_parts.rho[start+i] = local_rho;
    cuda_parts.entropy[start+i] = local_entropy;
    cuda_parts.entropy_dt[start+i] = local_entropy_dt;

    /* Copy the density union to the device */
    float local_wcount, local_wcount_dh, local_rho_dh, local_div_v;
    float3 local_rot_v;
    local_wcount = current->density.wcount;
    local_wcount_dh = current->density.wcount_dh;
    local_rho_dh = current->density.rho_dh;
    local_rot_v.x = current->density.rot_v[0];
    local_rot_v.y = current->density.rot_v[1];
    local_rot_v.z = current->density.rot_v[2];
    local_div_v = current->density.div_v;

    cuda_parts.wcount[start+i] = local_wcount;
    cuda_parts.wcount_dh[start+i] = local_wcount_dh;
    cuda_parts.rho_dh[start+i] = local_rho_dh;
    cuda_parts.rot_v[start+i] = local_rot_v;
    cuda_parts.div_v = local_div_v;

    /* Copy the force union to the device. TODO Do we need this?*/
    float local_balsara, local_f, local_P_over_rho2, local_soundspeed, local_vsig, local_h_dt;

    local_balsara = current->force.balsara;
    local_f = current->force.f;
    local_P_over_rho2 = current->force.P_over_rho2;
    local_soundspeed = current->force.soundspeed;
    local_v_sig = current->force.v_sig;
    local_h_dt = current->force.h_dt;

    cuda_parts.balsara[start+i] = local_balsara;
    cuda_parts.f[start+i] = local_f;
    cuda_parts.P_over_rho2[start+i] = local_P_over_rho2;
    cuda_parts.soundspeed[start+i] = local_soundspeed;
    cuda_parts.v_sig[start+i] = local_v_sig;
    cuda_parts.h_dt[start+i] = local_h_dt;

    cuda_parts.time_bin[start+i] = current->time_bin;
  }
}

/* Task function to unload a specific cell. */
/* TODO: Note that this copies back certain data that I expect is not modified.*/
__device__ void unload_cell( int cell_index ) {

  /* Get the pointer to the relevant cells. */
  struct cell *cpu_cell = &cpu_cells[cell_index];
  struct cell *cell = &cells[cell_index];
  struct part *parts = cpu_cell->parts;
  int i;
  /* Get the index to copy the data for the 0th particle in this cell to.*/
  int start = cell->first_part;

  for(i = threadIdx.x; i < cell->part_count; i+= blockDim.x )
  { 
    struct part *current = &parts[i];

    /* Copy back the ID and position.*/
    current->id = cuda_parts.id[start+i]
    current->x[0] = cuda_parts.x_x[start+i];
    current->x[1] = cuda_parts.x_y[start+i];
    current->x[2] = cuda_parts.x_z[start+i];

    /* Copy back the velocity*/
    float3 local_v = cuda_parts.v[start+i];
    current->v[0] = local_v.x;
    current->v[1] = local_v.y;
    current->v[2] = local_v.z;

    /* Copy back the acceleration */
    float3 local_a_hydro = cuda_parts.a_hydro[start+i];
    current->a_hydro[0] = local_a_hydro.x;
    current->a_hydro[1] = local_a_hydro.y;
    current->a_hydro[2] = local_a_hydro.z;

    /* Copy back the cutoff, mass, density, entropy and entropy_dt*/
    current->h = cuda_parts.h[start+i];
    current->mass = cuda_parts.mass[start+i];
    current->rho = cuda_parts.rho[start+i];
    current->entropy = cuda_parts.entropy[start+i];
    current->entropy_dt = cuda_parts.entropy_dt[start+i];

    /* Copy back the force union.*/
    current->force.balsara = cuda_parts.balsara[start+i];
    current->force.f = cuda_parts.f[start+i];
    current->force.P_over_rho2 = cuda_parts.P_over_rho2[start+i];
    current->force.soundspeed = cuda_parts.soundspeed[start+i];
    current->force.v_sig = cuda_parts.v_sig[start+i];
    current->force.h_dt = cuda_parts.h_dt[start+i];

    /* Copy back the timebin. */
    current->time_bin = cuda_parts.time_bin[start+i];
  }

}

/* Task function to execute a self-density task. */
__device__ void doself_density( struct cell_cuda *ci ) {

  /* Is the cell active? */
  if( !cuda_cell_is_active(ci) ) return;

  const int count_i = ci->count;
  int part_i = ci->first_part;
  float rho, rho_dh, div_v, wcount, wcount_dh;
  float3 rot_v;

  for( int pid = part_i + threadIdx.x; pid < part_i + count_i; pid += blockDim.x ) {
    double pix[3];
    pix[0] = cuda_parts.x_x[pid];
    pix[1] = cuda_parts.x_y[pid];
    pix[2] = cuda_parts.x_z[pid];
    const float hig2 = hi * hi * kernel_gamma2;

    /* Reset local values. */
    rho = 0.0f; rho_dh = 0.0f; div_v = 0.0f; wcount = 0.0f; wcount_dh = 0.0f;
    rot_v.x = 0.0f; rot_v.y = 0.0f; rot_v;z = 0.0f;

    /* If the particle isn't active skip it. */
    if(!cuda_part_is_active( pid ) ) 
      continue;

    /* Search for the neighbours! */
    for( int pjd = part_i; pjd < part_i + count_i; pjd ++ ) {
      /* Particles don't interact with themselves */
      if( pid == pjd )
        continue;
      dx[0] = pix[0] - cuda_parts.x_x[pjd];
      r2 += dx[0] * dx[0];
      dx[1] = pix[1] - cuda_parts.x_y[pjd];
      r2 += dx[1] * dx[1];
      dx[2] = pix[2] - cuda_parts.x_z[pjd];
      r2 += dx[2] * dx[2];

      /* If in range then interact. */
      if( r2 < hig2 ) {
        float wi, wi_dx;
        float dv[3], curlvr[3];

        /* Load mass on particle pj. */
        const float mj = cuda_parts.mass[pjd];

        /* Get r and 1/r */
        const float r = sqrtf(r2);
        const float ri = 1.0f / r;

        /* Compute the kernel function */
        const float hi_inv = 1.0f / hi;
        const float ui = r * hi_inv;
        
        cuda_kernel_deval(ui, &w, &dw_dx);

        /* Compute contribution to the density. */
        rho += mj * w;
        rho_dh -= mj * (hydro_dimension * w + ui * dw_dx);

        /* Compute contribution to the number of neighbours */
        wcount += w;
        wcount_dh -= ui * dw_dx

        const float fac = mj * dw_dx * ri;

        /* Compute dv dot r */
        float3 piv, pjv;
        piv = cuda_parts.v[pid];
        pjv = cuda_parts.v[pjd];
        dv[0] = piv.x - pjv.x;
        dv[1] = piv.y - pjv.y;
        dv[2] = piv.z - pjv.z;
        const float dvdr = dv[0] * dx[0] + dv[1] * dx[1] + dv[2] * dx[2];

        div_v -= fac*dvdr;

        curlvr[0] = dx[1] * dx[2] - dv[2] * dx[1];
        curlvr[1] = dv[2] * dx[0] - dv[0] * dx[2];
        curlvr[2] = dv[0] * dx[1] - dv[1] * dx[0];

        rot_v.x += fac*curlvr[0];
        rot_v.y += fac*curlvr[1];
        rot_v.z += fac*curlvr[2];
        
      } 
    }//Loop over cj.
    /* Write data for particle pid back to global stores. */
    atomicAdd( &cuda_parts.rho[pid], rho);
    atomicAdd( &cuda_parts.rho_dh[pid], rho_dh);
    atomicAdd( &cuda_parts.wcount[pid], wcount);
    atomicAdd( &cuda_parts.wcount_dh[pid], wcount_dh);
    atomicAdd( &cuda_parts.div_v[pid], div_v);
    atomic_add( &cuda_parts.rot_v[pid].x, rot_v.x);
    atomic_add( &cuda_parts.rot_v[pid].y, rot_v.y);
  }

}

/* Task function to execute a density task. Uses naive n^2 algorithm without symmetry*/
/* To do density between Cell i and cell j this needs to be called twice. */
__device__ void dopair_density( struct cell_cuda *ci, struct cell_cuda *cj ) {
 
 /* Are these cells active? */
  if( !cuda_cell_is_active(ci) && !cuda_cell_is_active(cj) ) return;

  const int count_i = ci->count;
  const int count_j = cj->count;
  int part_i = ci->first_part;
  int part_j = cj->first_part;
  float rho, rho_dh, div_v, wcount, wcount_dh;
  float3 rot_v;
  double shift[3] = {0.0, 0.0, 0.0};

  /* Deal with periodicity concerns. */
  for(int k = 0; k < 3; k++ ) {
    if( cj->loc[k] - ci->loc[k] < dim[k] / 2)
      shift[k] = dim[k];
    else if( cj->loc[k] - ci->loc[k] > dim[k] / 2 )
      shift[k] = dim[k]
  }

  /* Loop over the parts in cell ci */
  for( int pid = part_i + threadidx.x; pid < part_i+count_i; pid += blockDim.x ){

    const float hi = cuda_parts.h[pid];
    
    double pix[3];
    pix[0] = cuda_parts.x_x[pid] - shift[0];
    pix[1] = cuda_parts.x_y[pid] - shift[1];
    pix[2] = cuda_parts.x_z[pid] - shift[2];
    const float hig2 = hi * hi * kernel_gamma2;

    if(!part_is_active( pid ) )
      continue;

    /* Reset local values. */
    rho = 0.0f; rho_dh = 0.0f; div_v = 0.0f; wcount = 0.0f; wcount_dh = 0.0f;
    rot_v.x = 0.0f; rot_v.y = 0.0f; rot_v;z = 0.0f;


    /* Loop over the parts in cj. */
    /* TODO May be possible to optimize this loop ordering.*/
    for( int pjd = part_j; pjd < part_j + count_j; pjd++ ) {

      /* Compute the pairwise distance. */
      float r2 = 0.0f;
      float dx[3];
      dx[0] = pix[0] - cuda_parts.x_x[pjd];
      r2 += dx[0] * dx[0];
      dx[1] = pix[1] - cuda_parts.x_y[pjd];
      r2 += dx[1] * dx[1];
      dx[2] = pix[2] - cuda_parts.x_z[pjd];
      r2 += dx[2] * dx[2];

      /* If in range then interact. */
      if( r2 < hig2 ) {
        float wi, wi_dx;
        float dv[3], curlvr[3];

        /* Load mass on particle pj. */
        const float mj = cuda_parts.mass[pjd];

        /* Get r and 1/r */
        const float r = sqrtf(r2);
        const float ri = 1.0f / r;

        /* Compute the kernel function */
        const float hi_inv = 1.0f / hi;
        const float ui = r * hi_inv;
        
        cuda_kernel_deval(ui, &w, &dw_dx);

        /* Compute contribution to the density. */
        rho += mj * w;
        rho_dh -= mj * (hydro_dimension * w + ui * dw_dx);

        /* Compute contribution to the number of neighbours */
        wcount += w;
        wcount_dh -= ui * dw_dx

        const float fac = mj * dw_dx * ri;

        /* Compute dv dot r */
        float3 piv, pjv;
        piv = cuda_parts.v[pid];
        pjv = cuda_parts.v[pjd];
        dv[0] = piv.x - pjv.x;
        dv[1] = piv.y - pjv.y;
        dv[2] = piv.z - pjv.z;
        const float dvdr = dv[0] * dx[0] + dv[1] * dx[1] + dv[2] * dx[2];

        div_v -= fac*dvdr;

        curlvr[0] = dx[1] * dx[2] - dv[2] * dx[1];
        curlvr[1] = dv[2] * dx[0] - dv[0] * dx[2];
        curlvr[2] = dv[0] * dx[1] - dv[1] * dx[0];

        rot_v.x += fac*curlvr[0];
        rot_v.y += fac*curlvr[1];
        rot_v.z += fac*curlvr[2];
        
      } 
    }//Loop over cj.
    /* Write data for particle pid back to global stores. */
    atomicAdd( &cuda_parts.rho[pid], rho);
    atomicAdd( &cuda_parts.rho_dh[pid], rho_dh);
    atomicAdd( &cuda_parts.wcount[pid], wcount);
    atomicAdd( &cuda_parts.wcount_dh[pid], wcount_dh);
    atomicAdd( &cuda_parts.div_v[pid], div_v);
    atomic_add( &cuda_parts.rot_v[pid].x, rot_v.x);
    atomic_add( &cuda_parts.rot_v[pid].y, rot_v.y);
    atomic_add( &cuda_parts.rot_v[pid].z, rot_v.z);

  }//Loop over ci.
}

__device__ __inline__ void cuda_kernel_deval( float u, float *restrict W, float *restrict dW_dx) {
  /* Go to the range [0,1] from [0,H] */
  const float x = u * kernel_gamma_inv;

  /* Pick the correct branch of the kernel */
  const int temp = (int)(x*kernel_ivals_f);
  const int ind = temp > kernel_ivals ? kernel_ivals : temp;
  const float *coeffs = &kernel_coeffs[ind*(kernel_degree+1)];

  /* First two terms of the polynomial*/
  float w = coeffs[0] * x + coeffs[1];
  float dw_dx = coeffs[0];

  /* and the rest of them*/
  for(int k = 2; k <= kernel_degree; k++)
  {
    dw_dx = dw_dx * x + w;
    w = x * w + coeffs[k];
  }

  /* Return the results */
  *W = w * kernel_constant * kernel_gamma_inv_dim;
  *dW_dx = dw_dx * kernel_constant * kernel_gamma_inv_dim_plus_one;
}

/* Task function to perform a self force task. No symmetry */
__device__ void doself_force( struct celL_cuda *ci )
{
  /* Is the cell active? */
  if( !cuda_cell_is_active(ci) ) return;

  const int count_i = ci->count;
  int part_i = ci->first_part;

  float3 a_hydro;
  float h_dt, v_sig_stor, entropy_dt;

  /* Loop over the particles */
  for( int pid = part_i + threadIdx.x; pid < part_i + count_i; pid += blockDim.x ){

    const float hi = cuda_parts.h[pid];
    if( !cuda_part_is_active( pid ) )
      continue;
    /* Reset the values. */
    a_hydro.x = 0.0f; a_hydro.y = 0.0f; a_hydro.z = 0.0f;
    h_dt = 0.0f; v_sig_stor = cuda_parts.v_sig[pid]; entropy_dt = 0.0f;

    double pix[3];
    pix[0] = cuda_parts.x_x[pid];
    pix[1] = cuda_parts.x_y[pid];
    pix[2] = cuda_parts.x_z[pid];

    const float hig2 = hi * hi * kernel_gamma2;

    /* Loop over the particles in cj. */
    for( int pjd = part_i; pjd < part_i + count_i; pid++ ) {
    
      if(pid == pjd)
        continue;
      /* Compute the pairwise distance. */
      float r2 = 0.0f;
      float dx[3];
      dx[0] = pix[0] - cuda_parts.x_x[pjd];
      r2 += dx[0] * dx[0];
      dx[1] = pix[1] - cuda_parts.x_y[pjd];
      r2 += dx[1] * dx[1];
      dx[2] = pix[2] - cuda_parts.x_z[pjd];
      r2 += dx[2] * dx[2];

      const float hj = cuda_parts.h[pjd];
      if(r2 < hig2 || r2 < hj*hj*kernel_gamma2) {
        float wi, wj, wi_dx, wj_dx;
        const float fac_mu = 1.f; 

        const float r = sqrtf(r2);
        const float r_inv = 1.0f / r;

        /* Load some data.*/
        const float mj = cuda_parts.mass[pjd];
        const float rhoi = cuda_parts.rho[pid];
        const float rhoj = cuda_parts.rho[pjd];

        /* Get the kernel for hi. */
        const float hi_inv = 1.0f/hi;
        const float hid_inv = cuda_pow_dimension_plus_one(hi_inv);
        const float ui = r * hi_inv;
        cuda_kernel_deval(ui, &wi, &wi_dx)
        const float wi_dr = hid_inv * wi_dx;

        /* Get the kernel for hj. */
        const float hj_inv = 1.0f/hj;
        const float hjd_inv = cuda_pow_dimension_plus_one(hj_inv);
        const float xj = r * hj_inv;
        cuda_kernel_deval(xj, &wj, &wj_dx);
        const float wj_dr = hjd_inv * wj_dx;

        /* Compute h-gradient terms */
        const float f_i = cuda_parts.f[pid];
        const float f_j = cuda_parts.f[pjd];

        /* Compute pressure terms */
        const float P_over_rho2_i = cuda_parts.P_over_rho2[pid];
        const float P_over_rho2_j = cuda_parts.P_over_rho2[pjd];

        /* Compute sound speeds*/
        const float ci = cuda_parts.soundspeed[pid];
        const float cj = cuda_parts.soundspeed[pjd];

        /* Compute dv dot r. */
        const float dvdr = (cuda_parts.v[pid].x - cuda_parts.v[pjd].x) * dx[0] + 
                            cuda_parts.v[pid].y - cuda_parts.v[pjd].y) * dx[1] + 
                            cuda_parts.v[pid].z - cuda_parts.v[pjd].z) * dx[2];

        /* Balsara term */
        const float balsara_i = cuda_parts.balsara[pid];
        const float balsara_j = cuda_parts.balsara[pjd];

        /* Are the particles moving towards each other? */
        const float omega_ij = (dvdr < 0.f) ? dvdr : 0.f;
        const float mu_ij = fac_mu * r_inv * omega_id;

        /* Signal velocity */
        const float v_sig = ci + cj - 3.f * mu_ij;

        /* Now construct the full viscosity term */
        const float rho_ij = 0.5f* (rhoi+rhoj);
        const float visc = -0.25 * const_viscosity_alpha * v_sig * mu_id * 
                           (balsara_i + balsara_j) / rho_ij;

        /* Now convolce with the kernel */
        const float visc_term = 0.5f* visc * (wi_dr + wj_dr) * r_inv;
        const float sph_term = 
          (f_i * P_over_rho2_i * wi_dr + f_j * P_over_rho2_j * wj_dr) * r_inv;

        /* Compute the acceleration */
        const float acc = visc_term + sph_term;

        /* Compute the force */
        a_hydro.x -= mj * acc * dx[0];
        a_hydro.y -= mj * acc * dx[1];
        a_hydro.z -= mj * acc * dx[2];

        /* Get the time derivative for h. */
        h_dt -= mj * dvdr * r_inv / rhoj * wi_dr;

        /* Update the signal velocity. */
        v_sig_stor = (v_sig_stor > v_sig ) ? v_sig_stor : v_sig;

        /* Change in entropy */
        entropy_dt += mj * visc_term * dvdr;
      }

    } //Inner loop

    /* Flush to global stores.*/
    atomicAdd(&cuda_parts.a_hydro[pid].x, a_hydro.x);
    atomicAdd(&cuda_parts.a_hydro[pid].y, a_hydro.y);
    atomicAdd(&cuda_parts.a_hydro[pid].z, a_hydro.z);
    atomicAdd(&cuda_parts.h_dt[pid], h_dt);
    atomicAdd(&cuda_parts.entropy_dt[pid], entropy_dt);

    /* Update the signal velocity */
    float global_vsig = cuda_parts.v_sig[pid];
    int * address_as_int = (int*)&cuda_parts.v_sig[pid];
    int old = *address_as_int;
    int assumed;
    do{
      global_vsig = cuda_parts.v_sig[pid];
      assumed = old;
      if( v_sig_stor > global_vsig )
        old = atomicCAS(address_as_int, assumed, __float_as_int(global_vsig) );
    }while( assumed != old && v_sig_stor > global_vsig );
    
  } // Outer loop
}

/* Task function to execute a force task. Uses naive n^2 algorithm without symmetry*/
/* To do force between Cell i and cell j this needs to be called twice. */
__device__ void dopair_force( struct cell_cuda *ci, struct cell_cuda *cj) {

 /* Are these cells active? */
  if( !cuda_cell_is_active(ci) && !cuda_cell_is_active(cj) ) return;

  const int count_i = ci->count;
  const int count_j = cj->count;
  int part_i = ci->first_part;
  int part_j = cj->first_part;

  float3 a_hydro;
  float h_dt, v_sig_stor, entropy_dt;

  /* Deal with periodicity concerns. */
  for(int k = 0; k < 3; k++ ) {
    if( cj->loc[k] - ci->loc[k] < dim[k] / 2)
      shift[k] = dim[k];
    else if( cj->loc[k] - ci->loc[k] > dim[k] / 2 )
      shift[k] = dim[k]
  }

  /* Loop over the parts in cell ci */
  for( int pid = part_i + threadIdx.x; pid < part_i+count_i; pid += blockDim.x ){

    const float hi = cuda_parts.h[pid];
    if( !cuda_part_is_active( pid ) )
      continue;
    /* Reset the values. */
    a_hydro.x = 0.0f; a_hydro.y = 0.0f; a_hydro.z = 0.0f;
    h_dt = 0.0f; v_sig_stor = cuda_parts.v_sig[pid]; entropy_dt = 0.0f;

    double pix[3];
    pix[0] = cuda_parts.x_x[pid] - shift[0];
    pix[1] = cuda_parts.x_y[pid] - shift[1];
    pix[2] = cuda_parts.x_z[pid] - shift[2];

    const float hig2 = hi * hi * kernel_gamma2;

    /* Loop over the particles in cj. */
    for( int pjd = part_j; pjd < part_j + count_j; pjd++ ) {
     
      /* Compute the pairwise distance. */
      float r2 = 0.0f;
      float dx[3];
      dx[0] = pix[0] - cuda_parts.x_x[pjd];
      r2 += dx[0] * dx[0];
      dx[1] = pix[1] - cuda_parts.x_y[pjd];
      r2 += dx[1] * dx[1];
      dx[2] = pix[2] - cuda_parts.x_z[pjd];
      r2 += dx[2] * dx[2];

      const float hj = cuda_parts.h[pjd];
      if(r2 < hig2 || r2 < hj*hj*kernel_gamma2) {
        float wi, wj, wi_dx, wj_dx;
        const float fac_mu = 1.f; 

        const float r = sqrtf(r2);
        const float r_inv = 1.0f / r;

        /* Load some data.*/
        const float mj = cuda_parts.mass[pjd];
        const float rhoi = cuda_parts.rho[pid];
        const float rhoj = cuda_parts.rho[pjd];

        /* Get the kernel for hi. */
        const float hi_inv = 1.0f/hi;
        const float hid_inv = cuda_pow_dimension_plus_one(hi_inv);
        const float ui = r * hi_inv;
        cuda_kernel_deval(ui, &wi, &wi_dx)
        const float wi_dr = hid_inv * wi_dx;

        /* Get the kernel for hj. */
        const float hj_inv = 1.0f/hj;
        const float hjd_inv = cuda_pow_dimension_plus_one(hj_inv);
        const float xj = r * hj_inv;
        cuda_kernel_deval(xj, &wj, &wj_dx);
        const float wj_dr = hjd_inv * wj_dx;

        /* Compute h-gradient terms */
        const float f_i = cuda_parts.f[pid];
        const float f_j = cuda_parts.f[pjd];

        /* Compute pressure terms */
        const float P_over_rho2_i = cuda_parts.P_over_rho2[pid];
        const float P_over_rho2_j = cuda_parts.P_over_rho2[pjd];

        /* Compute sound speeds*/
        const float ci = cuda_parts.soundspeed[pid];
        const float cj = cuda_parts.soundspeed[pjd];

        /* Compute dv dot r. */
        const float dvdr = (cuda_parts.v[pid].x - cuda_parts.v[pjd].x) * dx[0] + 
                            cuda_parts.v[pid].y - cuda_parts.v[pjd].y) * dx[1] + 
                            cuda_parts.v[pid].z - cuda_parts.v[pjd].z) * dx[2];

        /* Balsara term */
        const float balsara_i = cuda_parts.balsara[pid];
        const float balsara_j = cuda_parts.balsara[pjd];

        /* Are the particles moving towards each other? */
        const float omega_ij = (dvdr < 0.f) ? dvdr : 0.f;
        const float mu_ij = fac_mu * r_inv * omega_id;

        /* Signal velocity */
        const float v_sig = ci + cj - 3.f * mu_ij;

        /* Now construct the full viscosity term */
        const float rho_ij = 0.5f* (rhoi+rhoj);
        const float visc = -0.25 * const_viscosity_alpha * v_sig * mu_id * 
                           (balsara_i + balsara_j) / rho_ij;

        /* Now convolce with the kernel */
        const float visc_term = 0.5f* visc * (wi_dr + wj_dr) * r_inv;
        const float sph_term = 
          (f_i * P_over_rho2_i * wi_dr + f_j * P_over_rho2_j * wj_dr) * r_inv;

        /* Compute the acceleration */
        const float acc = visc_term + sph_term;

        /* Compute the force */
        a_hydro.x -= mj * acc * dx[0];
        a_hydro.y -= mj * acc * dx[1];
        a_hydro.z -= mj * acc * dx[2];

        /* Get the time derivative for h. */
        h_dt -= mj * dvdr * r_inv / rhoj * wi_dr;

        /* Update the signal velocity. */
        v_sig_stor = (v_sig_stor > v_sig ) ? v_sig_stor : v_sig;

        /* Change in entropy */
        entropy_dt += mj * visc_term * dvdr;
        //INTERACT
      }

    } //Loop over cell cj.

    /* Flush to global stores.*/
    atomicAdd(&cuda_parts.a_hydro[pid].x, a_hydro.x);
    atomicAdd(&cuda_parts.a_hydro[pid].y, a_hydro.y);
    atomicAdd(&cuda_parts.a_hydro[pid].z, a_hydro.z);
    atomicAdd(&cuda_parts.h_dt[pid], h_dt);
    atomicAdd(&cuda_parts.entropy_dt[pid], entropy_dt);

    /* Update the signal velocity */
    float global_vsig = cuda_parts.v_sig[pid];
    int * address_as_int = (int*)&cuda_parts.v_sig[pid];
    int old = *address_as_int;
    int assumed;
    do{
      global_vsig = cuda_parts.v_sig[pid];
      assumed = old;
      if( v_sig_stor > global_vsig )
        old = atomicCAS(address_as_int, assumed, __float_as_int(global_vsig) );
    }while( assumed != old && v_sig_stor > global_vsig );
    

  }//Loop over cell ci.
}

/* Device function to finish the density calculation. */
__device__ void hydro_end_density( int pid ){

  const float h = cuda_parts.h[pid];
  const float h_inv = 1.0f/h;
  const float h_inv_dim = cuda_pow_dimension(h_inv);
  const float h_inv_dim_plus_one = h_inv_dim * h_inv;

  /* Final operation on the density (self-contribution) */
  float temp = cuda_parts[pid].mass * kernel_root;
  cuda_parts[pid].rho += temp;
  cuda_parts[pid].rho_dh -= hydro_dimension * temp;
  cuda_parts[pid].wcount += kernel_root;

  /* Finish the calculation by inser4ting the missing h-factors */
  cuda_parts[pid].rho *= h_inv_dim;
  cuda_parts[pid].rho_dh *= h_inv_dim_plus_one;
  cuda_parts[pid].wcount *= kernel_norm;
  cuda_parts[pid].wcount_dh *= h_inv * kernel_gamma * kernel_norm;

  const float rho_inv = 1.0 / cuda_parts[pid].rho;

  /* Finish the calculation of the velocity curl components. */
  cuda_parts[pid].rot_v.x *= h_inv_dim_plus_one * rho_inv;
  cuda_parts[pid].rot_v.y *= h_inv_dim_plus_one * rho_inv;
  cuda_parts[pid].rot_v.z *= h_inv_dim_plus_one * rho_inv;

  /* Finish calaculation fo the velocity divergence. */
  cuda_parts[pid].div_v *= h_inv_dim_plus_one * rho_inv;
}

__device__ void cuda_hydro_part_has_no_neighbours(int pid){
  const float h = cuda_parts[pid].h;
  const float h_inv = 1.0f / h;
  const float h_inv_dim = cuda_pow_dimension(h_inv);

  cuda_parts[pid].rho =  cuda_parts[pid].mass * kernel_root * h_inv_dim;
  cuda_parts[pid].wcount = kernel_root * kernel_norm * h_inv_dim;
  cuda_parts[pid].rho_dh = 0.f;
  cuda_parts[pid].wcount_dh = 0.f;
  cuda_parts[pid].div_v = 0.f;
  cuda_parts[pid].rot_v.x = 0.f;
  cuda_parts[pid].rot_v.y = 0.f;
  cuda_parts[pid].rot_v.z = 0.f;
}

__device__ float cuda_pow_gamma( float x ){
#if define(HYDRO_GAMMA_5_3)
  const float cbrt = cbrtf(x);
  return cbrt * cbrt * x;
#elif define(HYDRO_GAMMA_7_5)
  return powf(x, 1.4f);
#elif defined(HYDRO_GAMMA_4_3)
  return cbrtf(x) * x;
#elif defined(HYDRO_GAMMA_2_1)
  return x * x;
#else
  printf("The adiabatic index is not defined!");
  return 0.f;
#endif
}

/* USES IDEAL GAS ONLY */
__device__ float cuda_gas_pressure_from_entropy( float density, float entropy ){

  return entropy * cuda_pow_gamma(density);
}

__device__ float cuda_gas_soundspeed_from_pressure( float density, float P){
  
  const density_inv = 1.f / density;
  return sqrtf(hydro_gamma * P * density_inv);
}

__device__ void cuda_hydro_prepare_force(int pid){
  const float fac_mu = 1.f; /* Will change with cosmological integration. */

  /* Compute the norm of the curl */
  const float curl_v = sqrtf( cuda_parts[pid].rot_v.x * cuda_parts[pid].rot_v.x +
                              cuda_parts[pid].rot_v.y * cuda_parts[pid].rot_v.y + 
                              cuda_parts[pid].rot_v.z * cuda_parts[pid].rot_v.z);

  /* Compute the norm of div v */
  const float abs_div_v = fabsf(cuda_parts[pid].div_v);

  /* Compute the pressure */
  const float pressure = cuda_gas_pressure_from_entropy( cuda_parts[pid].rho,
                               cuda_parts[pid].entropy );

  /* Compute the soundspeed */
  const float soundspeed = cuda_gas_soundspeed_from_pressure( cuda_parts[pid].rho, pressure );

  const float rho_inv = 1.f / cuda_parts[pid].rho;
  const float P_over_rho2 = pressure * rho_inv * rho_inv;

  const float balsara =
    abs_div_v / (abs_div_v + curlv + 0.0001f * soundspeed / fac_mu / cuda_parts[pid].h);

  /* Compute the grah h term*/
  const float grad_h_term =
    1.f / (1.f + hydro_dimension_inv * cuda_parts[pid].h * cuda_parts[pid].rho_dh * rho_inv);

  /* Update variables */
  cuda_parts[pid].f = grad_h_term;
  cuda_parts[pid].P_over_rho2 = P_over_rho2;
  cuda_parts[pid].soundspeed = soundspeed;
  cuda_parts[pid].balsara = balsara;

}

/* Device function to fix a single particle that was messed up in the density loop. */
/* This interacts a single particle because the method used on the CPU will not work here*/
/* Its probably super inefficient but it should work at least...*/
__device__ void cuda_hydro_fix_particle( int pid, struct cell_cuda *c ){

  /* First we need to reset everything.. */
  cuda_parts[pid].rho = 0.f;
  cuda_parts[pid].wcount = 0.f;
  cuda_parts[pid].wcount_dh = 0.f;
  cuda_parts[pid].rho_dh = 0.f;
  cuda_parts[pid].div_v = 0.f;
  cuda_parts[pid].rot_v.x = 0.f;
  cuda_parts[pid].rot_v.y = 0.f;
  cuda_parts[pid].rot_v.z = 0.f;

 //TODO Fix the particle!
}

/* During ghost work only this block will be accessing the thread, no need for atomics. */
__device__ void do_ghost( struct cell_cuda *c ){

  int part_i = c->first_part;
  int count_i = c->part_count;
  /* Is the cell active? */
  if(!cuda_cell_is_active(c)) return;

  /* Recurse... */
  if( c->split ){
    for(int k = 0; k < 8; k++){
      if(c->progeny[k] >= 0) do_ghost( &cells[k] );
    }
  }else{

    /* Loop over the particles in the cell. */
    for(int i = threadIdx.x; i < part_i + count_i; i++)
    {
      if(!cuda_part_is_active(i)) continue;

      /* Finish the density calculation. */
      hydro_end_density(i);

      /* Did we get the right number of neighbours? */
      if( cuda_parts[i].wcount > max_wcount || cuda_parts[i].wcount < min_wcount) {
        
        float h_corr = 0.f;

        /* If no derivative, double the smoothing length. */
        if(cuda_parts[i].wcount_dh = 0.0f) 
          h_corr = cuda_parts[i].h;
        else{
          /* Otherwise, compute the smoothing length update (Newton step). */
          h_corr = (target_wcount - cuda_parts[i].wcount) / cuda_parts[i].wcount_dh;

          h_corr = (h_corr < cuda_parts[i].h) ? h_corr : cuda_parts[i].h;
          h_corr = (h_corr > -0.5f * cuda_parts[i].h) ? h_corr : -0.5f * cuda_parts[i].h;
        }

        /* Correct the value of h */
        cuda_parts[i].h += h_corr;

        //TODO If below absolute max try again
        //TODO else give up...
        if(cuda_parts[i].h < hydro_h_max) {

        }else{
          /* The particle is a lost cause */
          cuda_parts[i].h = hydro_h_max;

          /* Do some damage control if no neighbours were found */
          if(cuda_parst[i].wcount == kernel_root * kernel_norm)
            cuda_hydro_part_has_no_neighbours( i );
        }

      }/* correct number of neighbours */

      /* We now have a particle whose smoothing length has convegered */
      /* Time to set the force variables */
      /* Compute variables required for the force loop */
      cuda_hydro_prepare_force( i );

      /* The particle force values are now set. */
      /* Prepare the particle for the force loop over neighbours */
      cuda_parts[i].a_hydro.x = 0.0f;
      cuda_parts[i].a_hydro.y = 0.0f;
      cuda_parts[i].a_hydro.z = 0.0f;
      cuda_parts[i].entropy_dt = 0.0f;
      cuda_parst[i].h_dt = 0.0f;
      cuda_parst[i].v_sig = cuda_parts[i].soundspeed;

    } 
  }

}

/* Runner function to retrieve a task index from a queue. */
__device__ int runner_cuda_gettask( struct queue_cuda *q ) {

  int tid = -1;
  if( atomicAdd((int*)&q->nr_avail_tasks, -1) <= 0)
  {
    atomicAdd((int*)&q->nr_avail_tasks, 1);
    return -1;
  }

  /* Main loop */
  while( ( tid = cuda_queue_gettask( q ) ) >= 0 ){
    //TODO Do we need to lock anything here? Probably no.
    //TODO Does this need to be a while?
    break;
  }
  if( tid >= 0 ) {
    q->rec_data[atomicAdd( (int *)&q->rec_count, 1 ) ] = tid; //TODO Are we keeping rec_data
  }

  return tid;
}


/* The main kernel. */
__global__ void swift_device_kernel( )
{
  __shared__ volatile int tid;
  __shared__ volatile int done;
  int *src, *dest;
  int i;

  /* Main loop */
  while( 1 ){
    __syncthreads();
    /* Get a task from the queue. */
    if(threadIdx.x == 0){
      tid = -1;
      /* Highest Priority queue, unload tasks. */
      if(unload_queue.nr_avail_tasks > 0 ) {
        tid = runner_cuda_gettask( &unload_queue);
      }

      /* Next highest priority queue, load tasks. Only some blocks look in here */
      if(tid < 0 && load_queue.nr_avail_tasks > 0 && blockIdx.x < cuda_numloaders ) {
        tid = runner_cuda_gettask( &load_queue );
      }

      /* Finally loop through work queues in priority order. queue 0 is highest priority*/
      for( i = 0; i < cuda_numqueues && tid < 0; i++ ) {
        if( cuda_queues[i].nr_avail_tasks > 0 ){
          tid = runner_cuda_gettask( &cuda_queues[i] );
        }
      }

    }//Get task from queue

    /* Threads need to wait until they have work to do */
    __syncthreads();

    /* If the tasks are all complete and we don't have anything to do exit*/
    if(tid < 0 && tot_num_tasks == 0)
      break;

    if( tid < 0 )
      continue;

    int type = tasks[tid].type;
    int subtype = tasks[tid].subtype;

    if(type == type_load){
      load_cell( tasks[tid].ci );
    }else if(type == type_unload){
      unload_cell( tasks[tid].ci );
    }else if(type == task_type_pair || type == task_type_sub_pair){
      if(subtype == task_subtype_density){
        struct cell_cuda *ci = &cells_cuda(tasks[tid].ci);
        struct cell_cuda *cj = &cells_cuda(tasks[tid].cj);
        dopair_density(ci, cj);
      }else if(subtype == task_subtype_force){
        struct cell_cuda *ci = &cells_cuda(tasks[tid].ci);
        struct cell_cuda *cj = &cells_cuda(tasks[tid].cj);
        dopair_force(ci, cj);
      }
    }else if(type == task_type_self || type == task_type_sub_self){
      if(subtype == task_subtype_density){
        struct cell_cuda *ci = &cells_cuda(tasks[tid].ci);
        doself_density(ci);
      }else if(subtype == task_subtype_force){
        doself_force(ci);
      }
    }else if(type == task_type_ghost){
      struct cell_cuda *ci = &cells_cuda(tasks[tid].ci);
      do_ghost(ci);
    }

   __syncthreads();
  
    /* Unlock dependencies*/
    for( i = threadIdx.x; i < tasks[tid].nr_unlock_tasks; i++ ) {
      int dependant = tasks[tid].unlocks[i];
      if( atomicSub( &tasks[dependant].wait, 1 ) == 1 && !tasks[dependant].skip ) {
        if(tasks[dependant].type <= type_unload && tasks[dependant].type >= type_implicit_unload){
          cuda_queue_puttask(&unload_queue, dependant); 
        }else{
          if(tasks[dependant].weight >= median_cost)
          {
            cuda_queue_puttask( &cuda_queues[0], dependant);
          }else{
            cuda_queue_puttask( &cuda_queues[1], dependant);
          }
        }
      }
    }


  } // End of main loop


  /* Don't need to do any cleanup, all the dependencies and skips and queues are set by CPU. */
}

/*
 _____          _      
|  ___|        | |     
| |__ _ __   __| |     
|  __| '_ \ / _` |     
| |__| | | | (_| |     
\____/_| |_|\__,_|     
                       
                       
 _____  __             
|  _  |/ _|            
| | | | |_             
| | | |  _|            
\ \_/ / |              
 \___/|_|              
                       
                       
 _____                 
|  __ \
| |  \/_ __  _   _     
| | __| '_ \| | | |    
| |_\ \ |_) | |_| |    
 \____/ .__/ \__,_|    
      | |              
      |_|              
               _       
              | |      
  ___ ___   __| | ___  
 / __/ _ \ / _` |/ _ \
| (_| (_) | (_| |  __/ 
 \___\___/ \__,_|\___| 
                       
                       
  */

/* Host function to check cuda functions don't return errors */
__host__ inline void cudaErrCheck( cudaError_t status)
{
  if(status != cudaSuccess)
  {
    error(cudaGetErrorString(status);
  }
}

/* Host function to give all the cells the IDs required for CUDA order and tasks. */
__host__ void cell_IDs(struct cell *c, int *k){
  int i;
  c->cudaID = *k;
  *k = *k + 1;
  if(c->split){
    for(i = 0; i < 8; i++)
    {
      if(c->progeny[i] != NULL){
        cell_IDs(&c->progeny[i], k);
      }
    }
  }

}

/* Host function to create the load, unload and implicit tasks */
__host__ void create_transfer_tasks(struct cell *c, int *k, int parent_load_task, int parent_unload_task)
{
  tasks_host[*k].unlocks = malloc(sizeof(int) * 9); //For now we create CPU storage for these unlocks for each task. No task should have more than 9 unlocks to other transfer tasks.
  tasks_host[*k].nr_unlock_tasks = 0;
  tasks_host[*k].size_unlocks = 9;
  if(c->split){

    /* If the task is split we create implicit tasks to deal with dependencies. */
    tasks_host[*k].type = type_implicit_load;
    tasks_host[*k].ci = c->cuda_ID;
    tasks_host[*k].cj = -1; //These tasks operate on a single cell.
    tasks_host[*k].weight = c->count;
    tasks_host[*k].wait = 0;
    tasks_host[*k].subtype = task_subtype_none;
    tasks_host[*k].skip = 0;
    tasks_host[*k].implicit = 0;
    tasks_host[*k].task = NULL;
    /* The load implicit tasks unlocks the parent's task */
    if(parent_load_task >= 0){
      tasks_host[*k].unlocks[tasks_host[*k].nr_unlock_tasks++] = parent_load_task;
    }
    c->load_task = *k;
    *k = *k + 1;

    /* Create the implicit unload task. */
    tasks_host[*k].unlocks = malloc(sizeof(int) * 9); //For now we create CPU storage for these unlocks for each task. No task should have more than 9 unlocks to other transfer tasks.
    tasks_host[*k].nr_unlock_tasks = 0;
    tasks_host[*k].size_unlocks = 9;
    tasks_host[*k].type = type_implicit_unload;
    tasks_host[*k].ci = c->cuda_ID;
    tasks_host[*k].cj = -1; //These tasks operate on a single cell.
    tasks_host[*k].weight = c->count;
    tasks_host[*k].wait = 0;
    tasks_host[*k].subtype = task_subtype_none;
    tasks_host[*k].skip = 0;
    tasks_host[*k].implicit = 0;
    tasks_host[*k].task = NULL;
    
    /* The unload implicit task is unlocked by the parent task */
    if( parent_unload_task >= 0 ){
      tasks_host[parent_unload_task].unlocks[tasks_host[parent_unload_task].nr_unlock_tasks++] = *k;
    }
    c->unload_task = *k;
    *k = *k + 1;

    /* Recurse down the tree. */
    int load = *k-2;
    int unload = *k-1;
    for(int i = 0; i < 8; i++ )
    {
      if(c->progeny[i] != NULL)
        create_transfer_tasks( &c->progeny[i] , k, load, unload);
    }

  }else{
    /* Create the load task*/
    tasks_host[*k].type = type_load;
    tasks_host[*k].ci = c->cuda_ID;
    tasks_host[*k].cj = -1; //These tasks operate on a single cell.
    tasks_host[*k].weight = c->count;
    tasks_host[*k].wait = 0;
    tasks_host[*k].subtype = task_subtype_none;
    tasks_host[*k].skip = 0;
    tasks_host[*k].implicit = 0;
    tasks_host[*k].task = NULL;
    /* This load task unlocks the parent's task. */
    if(parent_load_task >= 0){
      tasks_host[*k].unlocks[tasks_host[*k].nr_unlock_tasks++] = parent_load_task;
    }
    c->load_task = *k;
    *k = *k + 1;

    /* Create the unload task */
    tasks_host[*k].unlocks = NULL; //unload tasks never unlock anything, end of tree.
    tasks_host[*k].nr_unlock_tasks = 0;
    tasks_host[*k].type = type_unload;
    tasks_host[*k].ci = c->cuda_ID;
    tasks_host[*k].cj = -1; //These tasks operate on a single cell.
    tasks_host[*k].weight = c->count;
    tasks_host[*k].wait = 0;
    tasks_host[*k].subtype = task_subtype_none;
    tasks_host[*k].skip = 0;
    tasks_host[*k].implicit = 0;
    tasks_host[*k].task = NULL;
    /* The unload task is unlocked by the parent task */
    if(parent_unload_task >= 0){
      tasks_host[parent_unload_task].unlocks[tasks_host[parent_unload_task].nr_unlock_tasks++] =  *k;
    }
    c->unload_task = *k;
    *k = *k + 1;
  }
}

/* Recursive function to create the cell structures require for the GPU.*/
__host__ void create_cells( struct cell *c, struct cell_cuda *cell_host, struct cell **host_pointers, struct part *parts){

  /* Set the host pointer. */
  host_ponters[c->cuda_ID] = c;
  struct cell_cuda *c2 = &cell_host[c->cuda_ID];

  c2->loc[0] = c->loc[0];
  c2->loc[1] = c->loc[1];
  c2->loc[2] = c->loc[2];
  c2->width[0] = c->width[0];
  c2->width[1] = c->width[1];
  c2->width[2] = c->width[2];
  c2->h_max = c->h_max;
  c2->first_part = c->first_part - parts;
  c2->part_count = c->part_count;
  c2->parent = c->parent->cuda_ID;
  c2->super = c->super->cuda_ID;
  c2->ti_end_min = c->ti_end_min;
  c2->ti_end_max = c->ti_end_max;
  c2->dmin = c->dmin;

  for(int i = 0; i < 8; i++)
  {
    /* Set progeny and recurse. */
    c2->progeny[i] = c->progeny[i]->cuda_ID;
    create_cells(c->progeny[i], cell_host, host_pointers, parts);
  }

}

/* Host function to perform quickselect */
__host__ int select(int* list, int left, int right, int n){
    static int value = -1;
    if(value < 0)
        value = right;
    if(left == right)
        return list[left];
    int pivotIndex = left + floor(r2() * (right-left+1));
    pivotIndex = partition(list, left, right, pivotIndex);
    if(n == pivotIndex)
        return list[n];
    else if ( n < pivotIndex){
        return select(list, left, pivotIndex-1, n);
    }else{
        return select(list, pivotIndex+1, right, n );
    }
}

/* Host function used for priority cutoff */
#define PERCENTILE 0.8
__host__ int find_priority_cutoff( struct task_cuda *tasks, int count ){

  int nr_work_tasks = 0;
  int *costs = malloc( sizeof(int) * count);
  for(i = 0; i < count; i++){
    if(tasks[i].type >= type_load){
      costs[nr_work_tasks++] = tasks[i].weight;
    }
  }
  int result = select(costs, 0, nr_work_tasks-1, (int) ((float)( nr_work_tasks-1 ) * 0.8f  ) );
  free(costs);
  return result;
}

/* Host function to update the GPU tasks and set skips and dependencies. */
__host__ void update_tasks(struct engine *e){

  struct scheduler *sched = &e->sched;
  struct space *s = &e->s;
  int nr_gpu_tasks, cut; 

  /* Download the cuda_tasks from the GPU. */
  cudaErrCheck( cudaMemcpyFromSymbol( &nr_gpu_tasks, cuda_numtasks, sizeof(int) ) );
  struct task_cuda *gpu_pointer = NULL;
  cudaErrCheck( cudaMemcpyFromSymbol( gpu_pointer, tasks_cuda, sizeof(struct task_cuda *) ) );//TODO check.
  struct task_cuda *host_tasks = NULL;
  host_tasks = (struct task_cuda *) malloc( sizeof(struct task_cuda) * nr_gpu_tasks );
  cudaErrCheck( cudaMemcpy( host_tasks, gpu_pointer, sizeof(struct task_cuda *) * nr_gpu_tasks,
       cudaMemcpyDeviceToHost ) );

  for(int i = 0; i < nr_gpu_tasks; i++)
  {
    //Update the skip flag and reset the wait to 0.
    host_tasks[i].wait = 0;
    if(host_tasks[i].type > type_load)
      host_tasks[i].skip = host_tasks[i].task->skip;
    else
      host_tasks[i].skip = 0;
  }

  /* Reset the waits. */
  for(int i = 0; i < nr_gpu_tasks; i++)
  {
    if(!host_tasks[i].skip){
      struct task_cuda *temp_t = &host_tasks[i];
      for(int ii = 0; ii < temp_t->nr_unlock_tasks; ii++) {
        host_tasks[ temp_t->unlocks[ii]].wait++;
      }
    }
  }

  /* Reset the queue data.*/
  int qsize;
  cudaErrCheck( cudaMemcpyFromSymbol( &qsize, cuda_queue_size, sizeof(int) ) );

  /* Remake the data array for the unload q and copy it*/
  /* Download the unload queue. */
  struct queue_cuda unload_host;
  cudaErrCheck( cudaMemcpyFromSymbol( &unload_host, unload_queue, sizeof(struct queue_cuda) ) );
  
  int *data = malloc(sizeof(int) * cuda_queue_size);
  int nr_unload;
  unload_host.count = 0;
  for(int i = 0; i < nr_gpu_tasks; i++)
  {
    if(host_tasks[i].type <= type_unload && host_tasks[i].type >= type_implicit_unload 
        && !host_tasks[i].skip){
      if(host_tasks[i].wait ==0)
      {
        data[unload_host.count++] = i;
      }
      nr_unload++;
    }
  for(i = unload_host.count; i < qsize; i++){
    data[i] = -1;
  }

  /* Allocate and copy the data to the device. */
  cudaErrCheck( cudaMemcpy( (void*) unload_host.data, data, sizeof(int) * qsize, 
       cudaMemcpyHostToDevice ) );
  unload_host.first = 0;
  unload_host.last = unload_host.count;
  unload_host.rec_count = 0;
  unload_host.nr_avail_tasks = unload_host.count;
  unload_host.count = nr_unload;

  /* Copy the queue to the device */
  cudaErrCheck( cudaMemcpyToSymbol( unload_queue, &unload_host , sizeof(struct queue_cuda) ) );
   

  /* Download the load queue. */
  struct queue_cuda load_host;
  cudaErrCheck( cudaMemcpyFromSymbol( &load_host, load_queue, sizeof(struct queue_cuda) ) );
  int nr_load;
  load_host.count = 0;
  for(int i = 0; i < nr_gpu_tasks; i++)
  {
    if(host_tasks[i].type == type_load 
        && !host_tasks[i].skip){
      if(host_tasks[i].wait ==0){
        data[load_host.count++] = i;
      }
      nr_load++;
    }
  for(i = load_host.count; i < qsize; i++){
    data[i] = -1;
  }

  /* Allocate and copy the data to the device. */
  cudaErrCheck( cudaMemcpy( (void*) load_host.data, data, sizeof(int) * qsize, 
       cudaMemcpyHostToDevice ) );
  load_host.first = 0;
  load_host.last = load_host.count;
  load_host.rec_count = 0;
  load_host.nr_avail_tasks = load_host.count;
  load_host.count = nr_load;

  /* Copy the queue to the device */
  cudaErrCheck( cudaMemcpyToSymbol( load_queue, &load_host , sizeof(struct queue_cuda) ) );
   

  /* Remake the data array for queue[0] and copy it */
  /* Download the work queues. */
  struct queue_cuda work_host[cuda_numqueues];
  cudaErrCheck( cudaMemcpyFromSymbol( &work_host, cuda_queues , sizeof(struct queue_cuda) * 2 ) );
  
  /* Download the priority. */
  int median_host;
  cudaErrCheck( cudaMemcpyFromSymbol( &median_host, median_cost, sizeof(int) ) );

  work_host[0].count = 0;
  int nr_work = 0;
  for(int i = 0; i < nr_gpu_tasks; i++)
  {
    if(host_tasks[i].type > type_load && !host_tasks[i].skip && host_tasks[i].weight >= median_host){
      if(hosts_tasks[i].wait == 0){
        data[work_host[0].count++] = i;
      }
      nr_work++;
    }
  }
  for(i = work_host[0].count; i < qsize; i++){
    data[i] = -1;
  }
 
  cudaErrCheck( cudaMemcpy( (void*) work_host.data, data, sizeof(int) * qsize, 
       cudaMemcpyHostToDevice ) );
  work_host[0].first = 0;
  work_host[0].last = work_host[0].count;
  work_host[0].rec_count = 0;
  work_host[0].nr_avail_tasks = work_host[0].count;
  work_host[0].count = nr_work;

  /* Remake the data array for queue[1] and copy it */
  work_host[1].count = 0;
  nr_work = 0;
  for(int i = 0; i < nr_gpu_tasks; i++)
  {
    if(host_tasks[i].type > type_load && !host_tasks[i].skip && host_tasks[i].weight < median_host){
      if(hosts_tasks[i].wait == 0){
        data[work_host[1].count++] = i;
      }
      nr_work++;
    }
  }
  for(i = work_host[1].count; i < qsize; i++){
    data[i] = -1;
  }
 
  cudaErrCheck( cudaMemcpy( (void*) work_host.data, data, sizeof(int) * qsize, 
       cudaMemcpyHostToDevice ) );
  work_host[1].first = 0;
  work_host[1].last = work_host[1].count;
  work_host[1].rec_count = 0;
  work_host[1].nr_avail_tasks = work_host[1].count;
  work_host[1].count = nr_work;

  cudaErrCheck( cudaMemcpyToSymbol( cuda_queues, &work_host , sizeof(struct queue_cuda) * 2 ) );

  /* Copy the tasks back to the GPU. */
  cudaErrCheck( cudaMemcpy( gpu_pointer, host_tasks, sizeof(struct task_cuda *) * nr_gpu_tasks,
       cudaMemcpyHostToDevice ) );

  /* Update simulation constants 
__device__ __constant__ integertime_t ti_current;
__device__ __constant__ double dim[3];
__device__ __constant__ timebin_t max_active_bin; */
  cudaErrCheck( cudaMemcpyToSymbol( ti_current, &e->ti_current, sizeof(integertime_t) ) );
  cudaErrCheck( cudaMemcpytoSymbol( dim, &e->s->dim, sizeof(double) * 3 ) );
  cudaErrCheck( cudaMemcpyToSymbol( max_active_bin, &e->max_active_bin, sizeof(timebin_t) ) );

  /* Clean up */
  free(host_tasks);
  free(data);
}

/* Host function to check if the supplied task should have a GPU version created. */
__host__ int is_gpu_task(struct task *t){

  int result = 0;
  for(int i = 0; i < num_gpu_types; i++){
    if(t->type == gpu_work_task_array[i])
      result = 1;
  }
  return result;
}

/* Host function to create the GPU tasks. Should be called whenever the tasks are recreated */
/* This function ignores skips but should work. Call update_tasks to ensure skips are set and */
/* waits are set correctly for the skips. */
__host__ void create_tasks(struct engine *e){

  struct scheduler *sched = &e->sched;
  struct space *s = &e->s;
  int num_gpu_tasks = 0;
  int i, k;
  struct cell *c;
  static int firstrun = 0;

  /* We only create density, ghost and force tasks on the device at current. */
  for(i = 0; i < sched->nr_tasks; i++)
  {
    if(is_gpu_task( &sched->tasks[i]; ) )
        num_gpu_tasks++;
  }

  /* We also create a load and unload task for every cell in the system */
  num_gpu_tasks += s->tot_cells * 2;

  /* Allocate page-locked memory for the host version of the GPU tasks. */
  cudaErrCheck( cudaMallocHost( (void**) &tasks_host, num_gpu_tasks * sizeof(struct task_cuda ) ) );

  k = 0;
  /* Loop through the cells and give them all an ID. */
  for(i = 0; i < cdim[0]*cdim[1]*cdim[2]; i++)
  {
    c = &s->cells_top[i];
    cell_IDs(c, &k);
  } 

  k = 0
  /* Create the tasks. */
  for(i = 0; i < sched->nr_tasks; i++){

    if(is_gpu_task( &sched->tasks[i]; ) ){
      /* Copy the data to the CUDA task. */
      struct task *t = &sched->tasks[i];
      tasks_host[k].flags = t->flags;
      tasks_host[k].rank = t->rank;
      tasks_host[k].weight = t->weight;
      tasks_host[k].nr_unlock_tasks = (int) t->nr_unlock_tasks;
      tasks_host[k].type = t->type;
      tasks_host[k].subtype = t->subtype;
      tasks_host[k].skip = t->skip;
      tasks_host[k].implicit = t->implicit;
      tasks_host[*k].size_unlocks = 0;

      tasks_host[k].ci = t->ci->cuda_ID;
      tasks_host[k].cj = t->cj->cuda_ID;

      /* We have a double linked structure because its easier to create. */
      tasks_host[k].task = t;
      t->cuda_task = k;
      k++;
    }
  }

  /* Create the data transfer tasks. */
  for(i = 0; i < cdim[0]*cdim[1]*cdim[2]; i++)
  {
    c = &s->cells_top[i];
    create_transfer_tasks( c , k, -1, -1);
  } 

  /* Check we got this right initially.. */
  if(k != num_gpu_tasks){
    error("We created a different number of GPU tasks than expected");
  }

  /* Now we have the tasks, time to start working on the dependencies. */
  
  /* Loop through the tasks */
  for(i = 0; i < num_gpu_tasks; i++)
  {
    /* The transfer tasks dependencies are done anyway so skip them. */
    if(tasks_host[i].type == type_load || tasks_host[i].type == type_unload || 
       tasks_host[i].type == type_implicit_load || tasks_host[i].type == type_implicit_unload )
        continue;

    /* Get the task. */
    struct task_cuda t = &tasks_host[i];

    /* How many dependencies did the CPU task have. */
    int deps = t->task->nr_unlock_tasks;

    /* If it is a force task then it also unlocks the unload tasks. */ 
    if(t->subtype == task_subtype_force){
      deps++;
      /* If its a pair force task then it needs 2 unlocks. */
      if( t->type == task_type_pair ){
        deps++;
      }
    }

    /* Allocate some CPU memory for the unlocks. */
    t->unlocks = malloc( sizeof(int) * deps );
    t->size_unlocks = deps;

    /* Copy the dependencies */
    for(int j = 0; j < t->task->nr_unlock_tasks; j++){
      t->unlocks[t->nr_unlock_tasks++] = t->task->unlocks[j]->cuda_task;
    }

    /* If it is a force task then add the unload tasks.*/
    if(t->subtype == task_subtype_force){
      t->unlocks[t->nr_unlock_tasks++] = t->task->ci->unload_task;
      if(t->type == task_type_pair ){
        t->unlocks[t->nr_unlock_tasks++] = t->task->cj->unload_task;
      }
    }

    /* If it is a density task then it is unlocked by the load task. */
    if(t->subtype == task_subtype_density){
      /* We may need to stretch the load task's unlocks */
      if(tasks_host[t->ci->load_task].nr_unlock_tasks == 
        tasks_host[t->ci->load_task].size_unlocks){
      
        int *temp = malloc(sizeof(int) * tasks_host[t->ci->lock_task].size_unlocks * 2);
        memcpy(temp, tasks_host[t->ci->load_task].unlocks,
           sizeof(int) * tasks_host[t->ci->load_task].nr_unlock_tasks );
        free(tasks_host[t->ci->load_task].unlocks);
        tasks_host[t->ci->load_task].unlocks = temp;

      }
      tasks_host[t->ci->load_task].unlock[tasks_host[t->ci->load_task].nr_unlock_tasks++] = i;

      if( t->type == task_type_pair ){
        /* We may need to stretch the load task's unlocks */
        if(tasks_host[t->cj->load_task].nr_unlock_tasks == 
          tasks_host[t->cj->load_task].size_unlocks){
        
          int *temp = malloc(sizeof(int) * tasks_host[t->cj->lock_task].size_unlocks * 2);
          memcpy(temp, tasks_host[t->cj->load_task].unlocks,
             sizeof(int) * tasks_host[t->cj->load_task].nr_unlock_tasks );
          free(tasks_host[t->cj->load_task].unlocks);
          tasks_host[t->cj->load_task].unlocks = temp;
  
        }
        tasks_host[t->cj->load_task].unlock[tasks_host[t->cj->load_task].nr_unlock_tasks++] = i;

      }//If is pair task.

    }//Load to density task dependencies.

  } //Loop over the tasks.


  /* Now we have the dependencies we need to squash them into a single array. */

  /* First we count how many there are.*/
  int num_deps = 0;
  for(i = 0; i < num_gpu_tasks; i++){
    num_deps += tasks_host[i].nr_unlock_tasks;
  }

  /* Create a storage location for the dependency array. */
  int *host_dependencies = malloc(sizeof(int) * num_deps);
  int deps_filled = 0;

  /* Add the arrays, update the pointers, remove the small arrays. */ 
  for(i = 0; i < num_gpu_tasks; i++){
    memcpy(&host_dependencies[deps_filled], tasks_host[i].unlocks, tasks_host[i].nr_unlock_tasks);
    free(tasks_host[i].unlocks);
    tasks_host[i].unlocks = &host_dependencies[deps_filled];
    deps_filled += tasks_host[i].nr_unlock_tasks;
  }

  /* Allocate storage for the dependencies on the GPU.*/
  int *gpu_dependencies = NULL;
  if(firstrun){
    /* If we already have an array for this we need to remove it. */
    cudaErrCheck(cudaMemcpyFromSymbol( gpu_dependencies, &cuda_unlocks, sizeof(int *) ) );
    cudaFree(gpu_dependencies);
    gpu_dependencies = NULL;
  }
  cudaErrCheck( cudaMalloc((void**) &gpu_dependencies, sizeof(int) * num_deps ));
  
  /* Start copying the dependency array to the device */ 
  cudaErrCheck( cudaMemcpyAsync(gpu_dependencies, host_dependencies, sizeof(int) * num_deps,
       cudaMemcpyHostToDevice ) );

  /* We need the task's unlock pointers to point at the device stuff, which we do with pointer maths */
  for(i = 0; i < num_gpu_tasks; i++){
    int *temp_p = gpu_dependencies + (tasks_host[i].unlocks - host_dependencies);
    tasks_host[i].unlocks = temp_p;
  }

  /* Wait for the transfer to complete.*/
  cudaErrCheck(cudaDeviceSynchronize());

  /* Copy the new device array to where it will be visible. */
  cudaErrCheck( cudaMemcpyToSymbol( cuda_unlocks, gpu_dependencies, sizeof(int *) ) );
  
  /* Copy the tasks to the device. */
  struct task_cuda *gpu_tasks= NULL;
  if(firstrun){
    cudaErrCheck( cudaMemcpyFromSymbol(gpu_tasks, &tasks, sizeof(struct task_cuda *) ) );
    cudaFree(gpu_tasks);
    gpu_tasks = NULL;
  }
  cudaErrCheck( cudaMalloc((void**) &gpu_tasks, sizeof(struct task_cuda) * num_gpu_tasks) );
  
  cudaErrCheck( cudaMemcpy(gpu_tasks, tasks_host, sizeof(struct task_cuda) * num_gpu_tasks,
        cudaMemcpyHostToDevice ) );

  cudaErrCheck( cudaMemcpyToSymbol( tasks, gpu_tasks, sizeof(struct task_cuda *) ) );


  /* Create the cuda_cells on the CPU. */
  struct cell_cuda *cell_host = malloc(sizeof(struct cell_cuda) * s->tot_cells); 
  struct cell **host_pointers = malloc(sizeof(struct *cell) * s->tot_cells);
  k = 0;
  for(int i = 0; i < nr_cells; i++)
  {
    c = &s->cells_top[i];
    /*Create cells recursively. */
    create_cells(c, cell_host, host_pointers, s->parts);
  }

  /* Allocate space on the device for the cells. */
  struct cell_cuda *cell_device = NULL;
  struct cell **pointers_device = NULL;
  if(firstrun){
    /* If we already have an array for this we need to remove it. */
    cudaErrCheck(cudaMemcpyFromSymbol( cell_device, &cells, sizeof(struct cell_cuda *) ) );
    cudaFree(cell_device);
    cudaErrCheck(cudaMemcpyFromSymbol( pointers_device, &cpu_cells, sizeof(struct cell **) ) );
    cudaFree(pointers_device);
    cell_device = NULL;
    pointers_device = NULL;
  }
  cudaErrCheck( cudaMalloc((void**) &cell_device, sizeof(struct cell_cuda ) * s->tot_cells ) );
  cudaErrCheck( cudaMalloc((void**)) &pointers_device, sizof(struct cell *) * s->tot_cells ) );
 
  /* Copy the cells and pointers to the device and set up the symbol. */
  cudaErrCheck( cudaMemcpy(cell_device, cell_host, sizeof(struct cell_cuda) * s->tot_cells,
        cudaMemcpyHostToDevice ) );

  cudaErrCheck( cudaMemcpyToSymbol( cells, cell_device, sizeof(struct cell_cuda *) ) );

  cudaErrCheck( cudaMemcpy( pointers_device, host_pointers, sizeof(struct cell *) * s->tot_cells, 
       cudaMemcpyHostToDevice );

  cudaErrCheck( cudaMemcpyToSymbol( cpu_cells, pointers_device, sizeof(struct cell **) ) );

  /* Setup the queues. */
  /* We have 4 queues, one containing unload & implicit tasks. */
  /* One containing load tasks only. */
  /* One containing high priority work tasks.*/
  /* Last one containing all other tasks. */
  struct queue_cuda load_host;
  struct queue_cuda unload_host;
  struct queue_cuda work_host[cuda_numqueues];
  int nr_load=0, nr_unload=0, nr_high=0, nr_low=0;

  /* Compute the 80th percentile for the work priorities.*/
  int cut = priority_cutoff( tasks_host,  num_gpu_tasks );

  /* cuda_queue_size is lazily set to fix all of the tasks in for now. If this becomes an issue
     it can be reduced */
  int qsize = max( num_gpu_tasks, 256 );
  cudaErrCheck( cudaMemcpyToSymbol( cuda_queue_size, &qsize, sizeof(int) ) );

  /* Set the waits! */
  for(i = 0; i < num_gpu_tasks; i++ ) {
    tasks_host[i].wait = 0;
  }
  for(i = 0; i < num_gpu_tasks; i++) {
    struct task_cuda *temp_t = &tasks_host[i];
    for(int ii = 0; ii < temp_t->nr_unlock_tasks; ii++)
    {
      tasks_host[ temp_t->unlocks[ii]].wait++;
    }
  }

  /* Create the queues */

  /* Create the buffers used to initialised the data and rec_data arrays. */
  int *data, data2;

  if( ( data = (int*) malloc(sizeof(int) * qsize ) ) == NULL )
    error("Failed to allocate the data buffer on the host.");
  if( ( data2 = (int*) malloc(sizeof(int) * qsize ) ) == NULL )
    error("Failed to allocate the rec_data buffer on the host.");

  load_host.count = 0;
  /* Find the load tasks */
  for( i = 0; i < num_gpu_tasks; i++ ) {
    if( tasks_host[i].type == type_load ) {
      if( tasks_host[i].wait == 0) {
        data[load_host.count] = i;
        data2[load_host.count++] = -1;
      }
      nr_load++;
    }
  }

  for(i = load_host.count; i < qsize; i++){
    data[i] = -1;
    data2[i] = -1;
  }

  /* Allocate and copy the data to the device. */
  cudaErrCheck( cudaMalloc( &load_host.data, sizeof(int) * qsize ) );
  cudaErrCheck( cudaMemcpy( (void*) load_host.data, data, sizeof(int) * qsize, 
       cudaMemcpyHostToDevice ) );
  cudaErrCheck( cudaMalloc( &load_host.rec_data, sizeof(int) * qsize ) );
  cudaErrCheck( cudaMemcpy( (void*) load_host.rec_data, data2, sizeof(int) * qsize, 
       cudaMemcpyHostToDevice ) );
  load_host.first = 0;
  load_host.last = load_host.count;
  load_host.rec_count = 0;
  load_host.nr_avail_tasks = load_host.count;
  load_host.count = nr_load;

  /* Copy the queue to the device */
  cudaErrCheck( cudaMemcpyToSymbol( load_queue, &load_host , sizeof(struct queue_cuda) ) );
 
 /* Create the unload queue. */
  unload_host.count = 0;
  for( i = 0; i < num_gpu_tasks; i++ ){
    if( tasks_host[i].type <= type_unload && tasks_host[i].type >= type_implicit_unload ){
      if( tasks_host[i].wait == 0 ) {
        data[unload_host.count] = i;
        data2[unload_host.count++] = -1;
      }
      nr_unload++;
    }
  }
  for(i = unload_host.count; i < qsize; i++){
    data[i] = -1;
    data2[i] = -1;
  }

  /* Allocate and copy the data to the device. */
  cudaErrCheck( cudaMalloc( &unload_host.data, sizeof(int) * qsize ) );
  cudaErrCheck( cudaMemcpy( (void*) unload_host.data, data, sizeof(int) * qsize, 
       cudaMemcpyHostToDevice ) );
  cudaErrCheck( cudaMalloc( &unload_host.rec_data, sizeof(int) * qsize ) );
  cudaErrCheck( cudaMemcpy( (void*) unload_host.rec_data, data2, sizeof(int) * qsize, 
       cudaMemcpyHostToDevice ) );
  unload_host.first = 0;
  unload_host.last = unload_host.count;
  unload_host.rec_count = 0;
  unload_host.nr_avail_tasks = unload_host.count;
  unload_host.count = nr_unload;

  /* Copy the queue to the device */
  cudaErrCheck( cudaMemcpyToSymbol( unload_queue, &unload_host , sizeof(struct queue_cuda) ) );


  /* Create the high priority queue. */

  work_host[0].count = 0;
  for( i = 0; i < num_gpu_tasks; i++ )
  {
    if(tasks_host[i].type > type_load && tasks_host[i].weight >= cut){ 
      if(tasks_host[i].wait == 0) {
        data[work_host[0].count] = i;
        data2[work_host[0].count++] = -1;
      }
      nr_high++;
    }
  }
  for(i = work_host[0].count; i < qsize; i++){
    data[i] = -1;
    data2[i] = -1;
  }

  /* Allocate and copy the data to the device. */
  cudaErrCheck( cudaMalloc( &work_host[0].data, sizeof(int) * qsize ) );
  cudaErrCheck( cudaMemcpy( (void*) work_host[0].data, data, sizeof(int) * qsize, 
       cudaMemcpyHostToDevice ) );
  cudaErrCheck( cudaMalloc( &work_host[0].rec_data, sizeof(int) * qsize ) );
  cudaErrCheck( cudaMemcpy( (void*) work_host[0].rec_data, data2, sizeof(int) * qsize, 
       cudaMemcpyHostToDevice ) );
  work_host[0].first = 0;
  work_host[0].last = work_host[0].count;
  work_host[0].rec_count = 0;
  work_host[0].nr_avail_tasks = work_host[0].count;
  work_host[0].count = nr_high;

  /* Create the low priority queue. */
  work_host[1].count = 0;
  for(i = 0; i < num_gpu_tasks; i++ )
  {
    if(tasks_host[i].type > type_load && tasks_host[i].weight < cut){
      if(tasks_host[i].wait == 0) {
        data[work_host[0].count] = i;
        data2[work_host[0].count++] = -1;
      }
      nr_low++;
    }
  }
  work_host[1].first = 0;
  work_host[1].last = work_host[0].count;
  work_host[1].rec_count = 0;
  work_host[1].nr_avail_tasks = work_host[1].count;
  work_host[1].count = nr_low;

  /* Copy the work queues to the GPU */
  cudaErrCheck( cudaMemcpyToSymbol( cuda_queues, &work_host , sizeof(struct queue_cuda) * 2 ) ); 


  /* Set some other values needed for scheduling. */
  cudaErrCheck( cudaMemcpyToSymbol( cuda_queue_size, &qsize, sizeof(int) ) );
  cudaErrCheck( cudaMemcpyToSymbol( cuda_numtasks , &num_gpu_tasks, sizeof(int) ) );
  cudaErrCheck( cudaMemcpyToSymbol( tot_num_tasks, &num_gpu_tasks, sizeof(int) ) );
  cudaErrCheck( cudaMemcpyToSymbol( median_cost, &cut, sizeof(int) ) );

  /* Allocate particle arrays on the GPU */
  struct particle_arrays host_pointers;
  if(firstrun){
    cudaErrCheck( cudaMemcpyFromSymbol( &host_pointers, cuda_parts, sizeof(struct particle_arrays) ) );  

    cudaErrCheck( cudaFree( host_pointers.id) );
    cudaErrCheck( cudaFree( host_pointers.x_x) );
    cudaErrCheck( cudaFree( host_pointers.x_y) );
    cudaErrCheck( cudaFree( host_pointers.x_z) );
    cudaErrCheck( cudaFree( host_pointers.v) );
    cudaErrCheck( cudaFree( host_pointers.a_hydro) );
    cudaErrCheck( cudaFree( host_pointers.h) );
    cudaErrCheck( cudaFree( host_pointers.mass) );
    cudaErrCheck( cudaFree( host_pointers.rho) );
    cudaErrCheck( cudaFree( host_pointers.entropy) );


    cudaErrCheck( cudaFree( host_pointers.wcount) );
    cudaErrCheck( cudaFree( host_pointers.wcount_dh) );
    cudaErrCheck( cudaFree( host_pointers.rho_dh) );
    cudaErrCheck( cudaFree( host_pointers.rot_v) );
    cudaErrCheck( cudaFree( host_pointers.div_v) );

    cudaErrCheck( cudaFree( host_pointers.balsara) );
    cudaErrCheck( cudaFree( host_pointers.f) );
    cudaErrCheck( cudaFree( host_pointers.P_over_rho2) );
    cudaErrCheck( cudaFree( host_pointers.soundspeed) );
    cudaErrCheck( cudaFree( host_pointers.v_sig) );
    cudaErrCheck( cudaFree( host_pointers.h_dt) );
    cudaErrCheck( cudaFree( host_pointers.time_bin) );
  }

  cudaErrCheck( cudaMalloc( &host_pointers.id, sizeof(long long int) * e->total_nr_parts ) );
  cudaErrCheck( cudaMalloc( &host_pointers.x_x, sizeof(double) * e->total_nr_parts ) );
  cudaErrCheck( cudaMalloc( &host_pointers.x_y, sizeof(double) * e->total_nr_parts ) );
  cudaErrCheck( cudaMalloc( &host_pointers.x_z, sizeof(double) * e->total_nr_parts ) );
  cudaErrCheck( cudaMalloc( &host_pointers.v, sizeof(float3) * e->total_nr_parts ) );
  cudaErrCheck( cudaMalloc( &host_pointers.a_hydro, sizeof(float3) * e->total_nr_parts ) );
  cudaErrCheck( cudaMalloc( &host_pointers.h, sizeof(float) * e->total_nr_parts ) );
  cudaErrCheck( cudaMalloc( &host_pointers.mass, sizeof(float) * e->total_nr_parts ) );
  cudaErrCheck( cudaMalloc( &host_pointers.rho, sizeof(float) * e->total_nr_parts ) );
  cudaErrCheck( cudaMalloc( &host_pointers.entropy, sizeof(float) * e->total_nr_parts ) );

  cudaErrCheck( cudaMalloc( &host_pointers.wcount, sizeof(float) * e->total_nr_parts ) );
  cudaErrCheck( cudaMalloc( &host_pointers.wcount_dh, sizeof(float) * e->total_nr_parts ) );
  cudaErrCheck( cudaMalloc( &host_pointers.rho_dh, sizeof(float) * e->total_nr_parts ) );
  cudaErrCheck( cudaMalloc( &host_pointers.rot_v, sizeof(float3) * e->total_nr_parts ) );
  cudaErrCheck( cudaMalloc( &host_pointers.div_v, sizeof(float) * e->total_nr_parts ) );

  cudaErrCheck( cudaMalloc( &host_pointers.balsara, sizeof(float) * e->total_nr_parts ) );
  cudaErrCheck( cudaMalloc( &host_pointers.f, sizeof(float) * e->total_nr_parts ) );
  cudaErrCheck( cudaMalloc( &host_pointers.P_over_rho2, sizeof(float) * e->total_nr_parts ) );
  cudaErrCheck( cudaMalloc( &host_pointers.soundspeed, sizeof(float) * e->total_nr_parts ) );
  cudaErrCheck( cudaMalloc( &host_pointers.v_sig, sizeof(float) * e->total_nr_parts ) );
  cudaErrCheck( cudaMalloc( &host_pointers.h_dt, sizeof(float) * e->total_nr_parts ) );

  cudaErrCheck( cudaMalloc( &host_pointers.time_bin, sizeof(time_bin_t) * e->total_nr_parts ) );

    cudaErrCheck( cudaMemcpyToSymbol( cuda_parts, &host_pointers, sizeof(struct particle_arrays) ) ); 

  cudaErrcheck( cudaMemcpyToSymbol( cuda_nr_parts, &e->total_nr_parts, sizeof(int) ) );
  /* This is no longer the first run. */
  firstrun = 1;
  /* Make sure we free everything we made here otherwise leaky code. */
  /* Free the tasks_host array. */
  cudaErrCheck( cudaFreeHost( tasks_host ) );
  tasks_host = NULL;
  /* Free the data and data 2 arrays.*/
  free(data); data = NULL;
  free(data2); data2 = NULL;
  /* Host dependency array has been copied now, so time to remove it.*/
  free(host_dependencies);
  host_dependencies = NULL;
  /* Free cell_host and host_pointers */
  free(cell_host); cell_host = NULL;
  free(host_pointers); host_pointers = NULL;
}
