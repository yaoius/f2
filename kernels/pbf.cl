#define PI 3.14159265358979323846264338327950288f
#define EPS_F 1e-22f

typedef struct fluid_params {
    uchar solver_iterations;
    float dt;
    float gravity;
    float kernel_h;
    float rest_density;
    float density_eps;
    float s_corr_k;
    float s_corr_dq_multiplier;
    float s_corr_n;
    float vort_eps;
    float visc_c;

    float grid_res;
    float x_min;
    float x_max;
    float y_min;
    float y_max;
    float z_min;
    float z_max;

    unsigned dim_x;
    unsigned dim_y;
    unsigned dim_z;
} fluid_params;

unsigned bin(unsigned dim_x, unsigned dim_y, uint3 b);
uint3 bin_index(unsigned dim_x, unsigned dim_y, unsigned dim_z, float bin_res, float3 p);

float poly6(float3 ri, float h);
float3 grad_spiky(float3 ri, float h);

__kernel
void predict_position(const fluid_params params,
                __global const float *pos,
                __global const float *vel,
                __global float *pred_pos) {

    size_t id = get_global_id(0);
    float3 pos_i = vload3(id, pos);
    float3 vel_i = vload3(id, vel);
    vel_i.y += params.gravity * params.dt;

    float3 pred = pos_i + vel_i * params.dt;

    vstore3(pred, id, pred_pos);
}

__kernel
void count_bins(const fluid_params params,
                __global const float *pred_pos,
                __global unsigned *bin_offset,
                __global unsigned *bin_counts) {

    size_t id = get_global_id(0);
    float3 pred_pos_i = vload3(id, pred_pos);

    uint3 b_index = bin_index(params.dim_x, params.dim_y, params.dim_z, params.grid_res, pred_pos_i);
    unsigned b = bin(params.dim_x, params.dim_y, b_index);

    bin_offset[id] = atomic_inc(&bin_counts[b]);
}

__kernel
void prefix_sum(__global const unsigned *bin_counts,
                __global unsigned *bin_starts) {

    size_t id = get_global_id(0);
    unsigned i, acc = 0;

    for (i = 0; i < id; ++i)
        acc += bin_counts[i];

    bin_starts[id] = acc;
}

__kernel
void reindex_particles(const fluid_params params,
                __global const unsigned *bin_starts,
                __global const unsigned *bin_offset,
                __global const float *pos,
                __global const float *pred_pos,
                __global float *r_pos,
                __global float *r_pred_pos) {

    unsigned id_old = get_global_id(0);
    float3 pred_pos_i = vload3(id_old, pred_pos);

    uint3 b_index = bin_index(params.dim_x, params.dim_y, params.dim_z, params.grid_res, pred_pos_i);
    unsigned b = bin(params.dim_x, params.dim_y, b_index);

    unsigned id_new = bin_starts[b] + bin_offset[id_old];

    vstore3(vload3(id_old, pos), id_new, r_pos);
    vstore3(vload3(id_old, pred_pos), id_new, r_pred_pos);
}

__kernel
void calculate_lambda(const fluid_params params,
                __global const unsigned *bin_starts,
                __global const unsigned *bin_counts,
                __global const float *pred_pos,
                __global float *lambda) {

    unsigned id_i = get_global_id(0);
    float3 pred_pos_i = vload3(id_i, pred_pos);

    unsigned num_bins = params.dim_x * params.dim_y * params.dim_z;
    uint3 b_index = bin_index(params.dim_x, params.dim_y, params.dim_z, params.grid_res, pred_pos_i);

    uint3 n_bin_index;
    int x, y, z;
    unsigned n_bin, n_bin_start, n_bin_end, id_j;
    float3 pred_pos_j, grad_ci_pk, r;

    float3 grad_ci_pi = (float3){0.f, 0.f, 0.f};
    float density = 0.f;
    float denom = 0.f;

    for (x = -1; x <= 1; ++x) {
        for (y = -1; y <= 1; ++y) {
            for (z = -1; z <= 1; ++z) {
                n_bin_index.x = (int) b_index.x + x;
                n_bin_index.y = (int) b_index.y + y;
                n_bin_index.z = (int) b_index.z + z;

                n_bin = bin(params.dim_x, params.dim_y, n_bin_index);

                if (n_bin >= num_bins)
                    continue;

                n_bin_start = bin_starts[n_bin];
                n_bin_end = n_bin_start + bin_counts[n_bin];

                for (id_j = n_bin_start; id_j < n_bin_end; ++id_j) {
                    pred_pos_j = vload3(id_j, pred_pos);
                    r = pred_pos_i - pred_pos_j;

                    density += poly6(r, params.kernel_h);

                    grad_ci_pk = grad_spiky(r, params.kernel_h);
                    if (id_i != id_j)
                        denom += dot(grad_ci_pk, grad_ci_pk);

                    grad_ci_pi += grad_ci_pk;
                }
            }
        }
    }

    denom += dot(grad_ci_pi, grad_ci_pi);
    float c_i = density / params.rest_density - 1.f;

    lambda[id_i] = -c_i / (denom / pow(params.rest_density, 2.f) + params.density_eps);
}

__kernel
void calculate_dp(const fluid_params params,
                __global const unsigned *bin_starts,
                __global const unsigned *bin_counts,
                __global const float *pred_pos,
                __global const float *lambda,
                __global float *d_pos) {

    unsigned id_i = get_global_id(0);
    float3 pred_pos_i = vload3(id_i, pred_pos);
    float lambda_i = lambda[id_i];

    unsigned num_bins = params.dim_x * params.dim_y * params.dim_z;
    uint3 b_index = bin_index(params.dim_x, params.dim_y, params.dim_z, params.grid_res, pred_pos_i);

    uint3 n_bin_index;
    int x, y, z;
    unsigned n_bin, n_bin_start, n_bin_end, id_j;
    float lambda_j, s_corr;
    float3 pred_pos_j, r;

    float3 acc = (float3){0.f, 0.f, 0.f};
    float s_corr_mult = -params.s_corr_k / pow(
            poly6(float3(params.s_corr_dq_multiplier, 0.f, 0.f), params.kernel_h),
            params.s_corr_n);

    for (x = -1; x <= 1; ++x) {
        for (y = -1; y <= 1; ++y) {
            for (z = -1; z <= 1; ++z) {
                n_bin_index.x = (int) b_index.x + x;
                n_bin_index.y = (int) b_index.y + y;
                n_bin_index.z = (int) b_index.z + z;
                n_bin = bin(params.dim_x, params.dim_y, n_bin_index);

                if (n_bin >= num_bins)
                    continue;

                n_bin_start = bin_starts[n_bin];
                n_bin_end = n_bin_start + bin_counts[n_bin];

                for (id_j = n_bin_start; id_j < n_bin_end; ++id_j) {
                    pred_pos_j = vload3(id_j, pred_pos);
                    lambda_j = lambda[id_j];
                    r = pred_pos_i - pred_pos_j;
                    s_corr = s_corr_mult * pow(poly6(r, params.kernel_h), params.s_corr_n);
                    acc += (lambda_i + lambda_j + s_corr) * grad_spiky(r, params.kernel_h);
                }
            }
        }
    }

    float3 dp = (1.f / params.rest_density) * acc;
    dp = clamp(dp, -0.1f, 0.1f);

    vstore3(dp, id_i, d_pos);
}

__kernel
void update_pred_position(const fluid_params params,
                __global const float *pred_pos,
                __global const float *d_pos,
                __global float *new_pred) {

    size_t id = get_global_id(0);
    float3 pred_pos_i = vload3(id, pred_pos);
    float3 dp_i = vload3(id, d_pos);

    float3 pred = clamp(
            pred_pos_i + dp_i,
            (float3){params.x_min + 0.02f, params.y_min + 0.02f, params.z_min + 0.02f},
            (float3){params.x_max - 0.02f, params.y_max - 0.02f, params.z_max - 0.02f});

    vstore3(pred, id, new_pred);
}

__kernel
void update_velocity(const fluid_params params,
                __global const float *pos,
                __global const float *pred_pos,
                __global float *vel) {

    size_t id = get_global_id(0);
    float3 pos_i = vload3(id, pos);
    float3 pred_pos_i = vload3(id, pred_pos);
    float3 v = (1.f / params.dt) * (pred_pos_i - pos_i);

    vstore3(v, id, vel);
}

__kernel
void calculate_vorticities(const fluid_params params,
                __global const unsigned *bin_starts,
                __global const unsigned *bin_counts,
                __global const float *pos,
                __global const float *vel,
                __global float *vort) {

    size_t id_i = get_global_id(0);
    float3 pos_i = vload3(id_i, pos);
    float3 vel_i = vload3(id_i, vel);

    unsigned num_bins = params.dim_x * params.dim_y * params.dim_z;
    uint3 b_index = bin_index(params.dim_x, params.dim_y, params.dim_z, params.grid_res, pos_i);

    uint3 n_bin_index;
    int x, y, z;
    unsigned n_bin, n_bin_start, n_bin_end, id_j;
    float3 v_ij, r;

    float3 w_i = (float3){0.f, 0.f, 0.f};

    for (x = -1; x <= 1; ++x) {
        for (y = -1; y <= 1; ++y) {
            for (z = -1; z <= 1; ++z) {
                n_bin_index.x = (int) b_index.x + x;
                n_bin_index.y = (int) b_index.y + y;
                n_bin_index.z = (int) b_index.z + z;

                n_bin = bin(params.dim_x, params.dim_y, n_bin_index);

                if (n_bin >= num_bins)
                    continue;

                n_bin_start = bin_starts[n_bin];
                n_bin_end = n_bin_start + bin_counts[n_bin];

                for (id_j = n_bin_start; id_j < n_bin_end; ++id_j) {
                    v_ij = vload3(id_j, vel) - vel_i;
                    r = pos_i - vload3(id_j, pos);
                    w_i += cross(v_ij, grad_spiky(r, params.kernel_h));
                }
            }
        }
    }

    vstore3(w_i, id_i, vort);
}

__kernel
void apply_visc_vort(const fluid_params params,
                __global const unsigned *bin_starts,
                __global const unsigned *bin_counts,
                __global const float *pos,
                __global const float *vel,
                __global const float *vort,
                __global float *vel_new) {

    size_t id_i = get_global_id(0);
    float3 pos_i = vload3(id_i, pos);
    float3 vel_i = vload3(id_i, vel);
    float3 w_i = vload3(id_i, vort);

    unsigned num_bins = params.dim_x * params.dim_y * params.dim_z;
    uint3 b_index = bin_index(params.dim_x, params.dim_y, params.dim_z, params.grid_res, pos_i);

    uint3 n_bin_index;
    int x, y, z;
    unsigned n_bin, n_bin_start, n_bin_end, id_j;
    float3 r;

    float3 grad_vort = (float3){0.f, 0.f, 0.f};
    float3 acc_visc = (float3){0.f, 0.f, 0.f};

    for (x = -1; x <= 1; ++x) {
        for (y = -1; y <= 1; ++y) {
            for (z = -1; z <= 1; ++z) {
                n_bin_index.x = (int) b_index.x + x;
                n_bin_index.y = (int) b_index.y + y;
                n_bin_index.z = (int) b_index.z + z;

                n_bin = bin(params.dim_x, params.dim_y, n_bin_index);

                if (n_bin >= num_bins)
                    continue;

                n_bin_start = bin_starts[n_bin];
                n_bin_end = n_bin_start + bin_counts[n_bin];

                for (id_j = n_bin_start; id_j < n_bin_end; ++id_j) {
                    r = pos_i - vload3(id_j, pos);
                    grad_vort += length(vload3(id_j, vort)) * grad_spiky(r, params.kernel_h);
                    acc_visc += poly6(r, params.kernel_h) * (vload3(id_j, vel) - vel_i);
                }
            }
        }
    }

    float l = length(grad_vort);
    if (l > EPS_F)
        grad_vort = (1.f / l) * grad_vort;

    float3 v = vel_i + params.visc_c * acc_visc + params.dt * params.vort_eps * cross(grad_vort, w_i);
    vstore3(v, id_i, vel_new);
}

inline unsigned bin(unsigned dim_x, unsigned dim_y, uint3 b) {
    return b.z * dim_x * dim_y + b.y * dim_x + b.x;
}

inline uint3 bin_index(unsigned dim_x, unsigned dim_y, unsigned dim_z, float bin_res, float3 p) {
    uint3 b;
    b.x = p.x / bin_res;
    b.y = p.y / bin_res;
    b.z = p.z / bin_res;
    return clamp(b, (uint3){0, 0, 0}, (uint3){dim_x - 1, dim_y - 1, dim_z - 1});
}

inline float poly6(float3 ri, float h) {
    float r = length(ri);
    if (r >= h || r < EPS_F)
        return 0.f;
    return (315.f / (64.f * PI * pow(h, 9.f))) * pow(h * h - r * r, 3.f);
}

inline float3 grad_spiky(float3 ri, float h) {
    float r = length(ri);
    if (r >= h || r < EPS_F)
        return float3(0, 0, 0);
    return (-45.f / (PI * pow(h, 6.f))) * pow(h - r, 2.f) * normalize(ri);
}
