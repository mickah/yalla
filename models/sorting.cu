// Simulating cell sorting with limited interactions.
#include <assert.h>
#include <cmath>

#include "../lib/inits.cuh"
#include "../lib/solvers.cuh"
#include "../lib/vtk.cuh"


const float R_MAX = 1;
const float R_MIN = 0.5;
const int N_CELLS = 100;
const int N_TIME_STEPS = 300;
const float DELTA_T = 0.05;

__device__ __managed__ Solution<float3, N_CELLS, LatticeSolver> X;


__device__ float3 cubic_sorting(float3 Xi, float3 Xj, int i, int j) {
    float3 dF = {0.0f, 0.0f, 0.0f};
    if (i == j) return dF;

    int strength = (1 + 2*(j < N_CELLS/2))*(1 + 2*(i < N_CELLS/2));
    float3 r = {Xi.x - Xj.x, Xi.y - Xj.y, Xi.z - Xj.z};
    float dist = fminf(sqrtf(r.x*r.x + r.y*r.y + r.z*r.z), R_MAX);
    float F = 2*(R_MIN - dist)*(R_MAX - dist) + (R_MAX - dist)*(R_MAX - dist);
    dF.x = strength*r.x*F/dist;
    dF.y = strength*r.y*F/dist;
    dF.z = strength*r.z*F/dist;
    assert(dF.x == dF.x);  // For NaN f != f.
    return dF;
}

__device__ __managed__ nhoodint<float3> p_sorting = cubic_sorting;


int main(int argc, char const *argv[]) {
    // Prepare initial state
    uniform_sphere(N_CELLS, R_MIN, X);
    int cell_type[N_CELLS];
    for (int i = 0; i < N_CELLS; i++) {
        cell_type[i] = (i < N_CELLS/2) ? 0 : 1;
    }

    // Integrate cell positions
    VtkOutput output("sorting");
    for (int time_step = 0; time_step <= N_TIME_STEPS; time_step++) {
        output.write_positions(N_CELLS, X);
        output.write_type(N_CELLS, cell_type);
        if (time_step == N_TIME_STEPS) return 0;

        X.step(DELTA_T, p_sorting);
    }
}
