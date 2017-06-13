// Simulate elongation of semisphere
#include <math.h>
#include <stdio.h>
#include <thread>
#include <functional>
#include <curand_kernel.h>
#include <thrust/fill.h>
#include <thrust/execution_policy.h>

#include "../include/cudebug.cuh"
#include "../include/dtypes.cuh"
#include "../include/solvers.cuh"
#include "../include/inits.cuh"
#include "../include/links.cuh"
#include "../include/polarity.cuh"
#include "../include/property.cuh"
#include "../include/vtk.cuh"


const auto n_0 = 15000;
const auto n_max = 65000;
const auto r_max = 1.f;
const auto r_protrusion = 1.5f;
const auto protrusion_strength = 0.1f;
const auto prots_per_cell = 1;
const auto n_time_steps = 1000*50;
const auto skip_steps = 5*50;
const auto proliferation_rate = 1.386/n_time_steps;  // log(fold-change: 4) = 1.386
const auto dt = 0.2f;
enum Cell_types {mesenchyme, epithelium, aer};

MAKE_PT(Lb_cell, w, f, theta, phi);


__device__ Cell_types* d_type;
__device__ int* d_mes_nbs;  // number of mesenchymal neighbours
__device__ int* d_epi_nbs;

__device__ Lb_cell lb_force(Lb_cell Xi, Lb_cell r, float dist, int i, int j) {
    Lb_cell dF {0};
    if (i == j) {
        // D_ASSERT(Xi.w >= 0);
        dF.w = (d_type[i] > mesenchyme) - 0.01*Xi.w;
        dF.f = (d_type[i] == aer) - 0.01*Xi.f;
        return dF;
    }

    if (dist > r_max) return dF;

    float F;
    if (d_type[i] == d_type[j]) {
        F = fmaxf(0.7 - dist, 0)*2 - fmaxf(dist - 0.8, 0)/2;
    } else {
        F = fmaxf(0.8 - dist, 0)*2 - fmaxf(dist - 0.9, 0)/2;
    }
    dF.x = r.x*F/dist;
    dF.y = r.y*F/dist;
    dF.z = r.z*F/dist;
    auto D = dist < r_max ? 0.1 : 0;
    dF.w = - r.w*D;
    dF.f = - r.f*D;

    if (d_type[j] == mesenchyme) d_mes_nbs[i] += 1;
    else d_epi_nbs[i] += 1;

    if (d_type[i] == mesenchyme or d_type[j] == mesenchyme) return dF;

    dF += rigidity_force(Xi, r, dist)*0.2;
    return dF;
}


__global__ void update_protrusions(const Lattice<n_max>* __restrict__ d_lattice,
        const Lb_cell* __restrict d_X, int n_cells, Link* d_link, curandState* d_state) {
    auto i = blockIdx.x*blockDim.x + threadIdx.x;
    if (i >= n_cells*prots_per_cell) return;

    auto j = static_cast<int>((i + 0.5)/prots_per_cell);
    auto rand_nb_cube = d_lattice->d_cube_id[j]
        + d_moore_nhood[min(static_cast<int>(curand_uniform(&d_state[i])*27), 26)];
    auto cells_in_cube = d_lattice->d_cube_end[rand_nb_cube] - d_lattice->d_cube_start[rand_nb_cube];
    if (cells_in_cube < 1) return;

    auto a = d_lattice->d_cell_id[j];
    auto b = d_lattice->d_cell_id[d_lattice->d_cube_start[rand_nb_cube]
        + min(static_cast<int>(curand_uniform(&d_state[i])*cells_in_cube), cells_in_cube - 1)];
    D_ASSERT(a >= 0); D_ASSERT(a < n_cells);
    D_ASSERT(b >= 0); D_ASSERT(b < n_cells);
    if (a == b) return;

    if ((d_type[a] != mesenchyme) or (d_type[b] != mesenchyme)) return;

    auto new_r = d_X[a] - d_X[b];
    auto new_dist = norm3df(new_r.x, new_r.y, new_r.z);
    if (new_dist > r_protrusion) return;

    auto link = &d_link[a*prots_per_cell + i%prots_per_cell];
    auto not_initialized = link->a == link->b;
    auto old_r = d_X[link->a] - d_X[link->b];
    auto old_dist = norm3df(old_r.x, old_r.y, old_r.z);
    auto noise = curand_uniform(&d_state[i]);
    auto more_along_w = fabs(new_r.w/new_dist) > fabs(old_r.w/old_dist)*(1.f - noise);
    auto high_f = (d_X[a].f + d_X[b].f) > 1;
    if (not_initialized or more_along_w or high_f) {
        link->a = a;
        link->b = b;
    }
}


__global__ void proliferate(float mean_distance, Lb_cell* d_X, int* d_n_cells,
        curandState* d_state) {
    D_ASSERT(*d_n_cells*proliferation_rate <= n_max);
    auto i = blockIdx.x*blockDim.x + threadIdx.x;
    if (i >= *d_n_cells*(1 - proliferation_rate)) return;  // Dividing new cells is problematic!

    switch (d_type[i]) {
        case mesenchyme: {
            auto r = curand_uniform(&d_state[i]);
            if (r > proliferation_rate) return;
            break;
        }
        default:
            if (d_epi_nbs[i] > d_mes_nbs[i]) return;
    }

    auto n = atomicAdd(d_n_cells, 1);
    auto theta = curand_uniform(&d_state[i])*2*M_PI;
    auto phi = curand_uniform(&d_state[i])*M_PI;
    d_X[n].x = d_X[i].x + mean_distance/4*sinf(theta)*cosf(phi);
    d_X[n].y = d_X[i].y + mean_distance/4*sinf(theta)*sinf(phi);
    d_X[n].z = d_X[i].z + mean_distance/4*cosf(theta);
    d_X[n].w = d_X[i].w/2;
    d_X[i].w = d_X[i].w/2;
    d_X[n].f = d_X[i].f/2;
    d_X[i].f = d_X[i].f/2;
    d_X[n].theta = d_X[i].theta;
    d_X[n].phi = d_X[i].phi;
    d_type[n] = d_type[i];
}


int main(int argc, char const *argv[]) {
    // Prepare initial state
    Solution<Lb_cell, n_max, Lattice_solver> bolls(n_0);
    uniform_sphere(0.733333, bolls);
    Property<n_max, Cell_types> type;
    cudaMemcpyToSymbol(d_type, &type.d_prop, sizeof(d_type));
    for (auto i = 0; i < n_0; i++) {
        bolls.h_X[i].x = fabs(bolls.h_X[i].x);
        bolls.h_X[i].y = bolls.h_X[i].y/1.5;
        bolls.h_X[i].w = 0;
        type.h_prop[i] = mesenchyme;
    }
    bolls.copy_to_device();
    type.copy_to_device();
    Property<n_max, int> n_mes_nbs;
    cudaMemcpyToSymbol(d_mes_nbs, &n_mes_nbs.d_prop, sizeof(d_mes_nbs));
    Property<n_max, int> n_epi_nbs;
    cudaMemcpyToSymbol(d_epi_nbs, &n_epi_nbs.d_prop, sizeof(d_epi_nbs));
    Links<static_cast<int>(n_max*prots_per_cell)> protrusions(protrusion_strength,
        n_0*prots_per_cell);
    auto intercalation = std::bind(
        link_forces<static_cast<int>(n_max*prots_per_cell), Lb_cell>,
        protrusions, std::placeholders::_1, std::placeholders::_2);

    // Relax
    for (auto time_step = 0; time_step <= 200; time_step++) {
        bolls.build_lattice(r_protrusion);
        update_protrusions<<<(protrusions.get_d_n() + 32 - 1)/32, 32>>>(bolls.d_lattice,
            bolls.d_X, bolls.get_d_n(), protrusions.d_link, protrusions.d_state);
        thrust::fill(thrust::device, n_mes_nbs.d_prop, n_mes_nbs.d_prop + n_0, 0);
        bolls.take_step<lb_force>(dt, intercalation);
    }

    // Find epithelium
    bolls.copy_to_host();
    n_mes_nbs.copy_to_host();
    for (auto i = 0; i < n_0; i++) {
        if (n_mes_nbs.h_prop[i] < 12*2 and bolls.h_X[i].x > 0) {  // 2nd order solver
            if (fabs(bolls.h_X[i].y) < 0.75 and bolls.h_X[i].x > 3)
                type.h_prop[i] = aer;
            else
                type.h_prop[i] = epithelium;
            auto dist = sqrtf(bolls.h_X[i].x*bolls.h_X[i].x
                + bolls.h_X[i].y*bolls.h_X[i].y + bolls.h_X[i].z*bolls.h_X[i].z);
            bolls.h_X[i].theta = acosf(bolls.h_X[i].z/dist);
            bolls.h_X[i].phi = atan2(bolls.h_X[i].y, bolls.h_X[i].x);
        } else {
            bolls.h_X[i].theta = 0;
            bolls.h_X[i].phi = 0;
        }
        bolls.h_X[i].w = 0;
        bolls.h_X[i].f = 0;
    }
    bolls.copy_to_device();
    type.copy_to_device();
    protrusions.reset();
    bolls.take_step<lb_force>(dt, intercalation);  // Relax epithelium before proliferate

    // Simulate diffusion & intercalation
    Vtk_output output("elongation");
    for (auto time_step = 0; time_step <= n_time_steps/skip_steps; time_step++) {
        bolls.copy_to_host();
        protrusions.copy_to_host();
        type.copy_to_host();

        std::thread calculation([&] {
            for (auto i = 0; i < skip_steps; i++) {
                proliferate<<<(bolls.get_d_n() + 128 - 1)/128, 128>>>(0.733333, bolls.d_X,
                    bolls.d_n, protrusions.d_state);
                protrusions.set_d_n(bolls.get_d_n()*prots_per_cell);
                bolls.build_lattice(r_protrusion);
                update_protrusions<<<(protrusions.get_d_n() + 32 - 1)/32, 32>>>(bolls.d_lattice,
                    bolls.d_X, bolls.get_d_n(), protrusions.d_link, protrusions.d_state);
                thrust::fill(thrust::device, n_mes_nbs.d_prop, n_mes_nbs.d_prop + bolls.get_d_n(), 0);
                thrust::fill(thrust::device, n_epi_nbs.d_prop, n_epi_nbs.d_prop + bolls.get_d_n(), 0);
                bolls.take_step<lb_force>(dt, intercalation);
            }
        });

        output.write_positions(bolls);
        output.write_links(protrusions);
        output.write_property(type);
        // output.write_polarity(bolls);
        output.write_field(bolls, "Wnt");
        output.write_field(bolls, "Fgf", &Lb_cell::f);

        calculation.join();
    }

    return 0;
}