#include "cuda_runtime.h"
#include "cudafacegraph.h"
#include "device_launch_parameters.h"
#include <omp.h>

#define BLOCK_SIZE 512

CUDAFaceGraph::CUDAFaceGraph(std::vector<Triangle>* triangles, DS_timer* timer) : FaceGraph(triangles, timer) {
    init();
}

CUDAFaceGraph::CUDAFaceGraph(std::vector<Triangle>* triangles) : FaceGraph(triangles) {
    init();
}

struct VertexHash {
    int vertex[3];
};

struct AdjacentNode {
    glm::vec3* vertex = nullptr;
    int* adjacents;
    int filled_index = 0;
} typedef AdjacentNode;

__device__ bool is_connected_device(const Triangle& a, const Triangle& b) {
    int shared_vertices = 0;

    for (auto i : a.vertex) {
        for (auto j : b.vertex) {
            if (glm::all(glm::equal(i, j))) {
                shared_vertices++;
                break;
            }
        }
    }

    return (shared_vertices > 1);
}

__global__ void cuda_union_find(Triangle* triangles, int triangle_idx, int* adj_triangles, int* adjacents,
                                int adjacents_size) {
    int idx = blockDim.x * blockIdx.x + threadIdx.x;
    if (idx >= adjacents_size)
        return;
    /*if (threadIdx.x == 0)
        printf("%d\n", adjacents_size);*/
    // 맞닿아 있는 삼각형이,
    int adjacent_triangle = adjacents[idx];
    // 원래의 삼각형과도 맞닿아 있으면 루트를 원래의 삼각형으로 지정.
    if (is_connected_device(triangles[triangle_idx], triangles[adjacent_triangle])) {
        // printf("%d,%d : %d %d\n", triangle_idx, adjacent_triangle, adj_triangles[triangle_idx],
        //        adj_triangles[adjacent_triangle]);
        if (adj_triangles[adjacent_triangle] > adj_triangles[triangle_idx])
            adj_triangles[adjacent_triangle] = adj_triangles[triangle_idx];
        else if (adj_triangles[adjacent_triangle] < adj_triangles[triangle_idx])
            adj_triangles[triangle_idx] = adj_triangles[adjacent_triangle];
    }
}

__global__ void cuda_union_find_all(Triangle* triangles, AdjacentNode* adjacent_nodes,
                                    VertexHash* vertex_hash_list, int* triangles_parents) {
    int i = blockDim.x * blockIdx.x + threadIdx.x;
    for (int j = 0; j < 3; j++) {

        glm::vec3 vertex = triangles[i].vertex[j];

        size_t vertex_hash = vertex_hash_list[i].vertex[j];
        AdjacentNode* node = &adjacent_nodes[vertex_hash];

        int* adjacents = node->adjacents;

        for(int k = 0; k < node->filled_index; k++){
            Triangle tri_idx = triangles[i];
            Triangle tri_adj = triangles[adjacents[j]];
            if (is_connected_device(tri_idx, tri_adj))
            if(triangles_parents[adjacents[j]] > triangles_parents[i])
                triangles_parents[adjacents[j]] = triangles_parents[i];
        }
    }
}

void CUDAFaceGraph::init() {
    timer->onTimer(TIMER_FACEGRAPH_INIT_A);
    /* 변수 선언 */
    Vec3Hash hash_function;
    size_t vertex_size = triangles->size() * 3;
    omp_lock_t* locks = new_locks(vertex_size);
    // 해제 주의
    VertexHash* vertex_hash_list;
    /* 초기화 */
    vertex_hash_list = new VertexHash[vertex_size];
    /* 해시 리스트 초기화 및 카운트 세기 */
    int* over_count_map = new int[vertex_size];
    std::fill_n(over_count_map, vertex_size, 0);
    // duplicated_vertex_key에 중복 vertex들의 triangle 포함 횟수 합산

#pragma omp parallel for
    for (int i = 0; i < triangles->size(); i++) {
        for (int j = 0; j < 3; j++) {
            glm::vec3 vertex = triangles->at(i).vertex[j];
            size_t index = vertex_hash_list[i].vertex[j] = hash_function(vertex) % vertex_size;
#pragma omp atomic
            over_count_map[index]++;
        }
    }

    int max_count = 0;
    // #pragma omp parallel for reduction(max:max_count)
    for (int i = 0; i < vertex_size; i++) {
        if (over_count_map[i] > max_count) {
            max_count = over_count_map[i];
        }
    }

    AdjacentNode* adjacent_nodes = new AdjacentNode[vertex_size];
#pragma omp parallel for
    for (int i = 0; i < triangles->size(); i++) {
        for (int j = 0; j < 3; j++) {
            glm::vec3& vertex = triangles->at(i).vertex[j];
            size_t vertex_hash = vertex_hash_list[i].vertex[j];
            bool is_exist = false;
            AdjacentNode* node = &adjacent_nodes[vertex_hash];

            size_t locked_hash = vertex_hash;
            omp_set_lock(&locks[locked_hash]);
            while (node->vertex != nullptr) {
                glm::vec3* target = node->vertex;
                if (vertex == *target) {
                    is_exist = true;
                    break;
                }
                vertex_hash = (vertex_hash + 1) % vertex_size;
                node = &adjacent_nodes[vertex_hash];
            }
            vertex_hash_list[i].vertex[j] = vertex_hash;
            omp_unset_lock(&locks[locked_hash]);

            omp_set_lock(&locks[vertex_hash]);
            if (!is_exist) {
                node->vertex = &vertex;
                node->adjacents = new int[max_count];
                std::fill_n(node->adjacents, max_count, false);
            }
            node->adjacents[node->filled_index++] = i;
            omp_unset_lock(&locks[vertex_hash]);
        }
    }

    timer->offTimer(TIMER_FACEGRAPH_INIT_A);

    timer->onTimer(TIMER_FACEGRAPH_INIT_B);
    // 각 면에 대한 인접 리스트 생성.
    adj_triangles = std::vector<std::vector<int>>(triangles->size());
    triangles_parents = std::vector<int>(triangles->size());
// 각 삼각형의 root를 자신으로 초기화
#pragma omp parallel for
    for (int i = 0; i < triangles->size(); i++) {
        triangles_parents[i] = i;
    }

    Triangle* dev_triangles;
    cudaMalloc(&dev_triangles, triangles->size() * sizeof(Triangle));
    cudaMemcpy(dev_triangles, triangles->data(), triangles->size() * sizeof(Triangle), cudaMemcpyHostToDevice);

    int* dev_triangles_parents;
    cudaMalloc(&dev_triangles_parents, triangles->size() * sizeof(int));
    cudaMemcpy(dev_triangles_parents, triangles_parents.data(), triangles->size() * sizeof(int),
               cudaMemcpyHostToDevice);
    int* dev_adjacents;
    cudaMalloc(&dev_adjacents, triangles->size() * sizeof(int));
    cudaMalloc(&dev_triangles_parents, triangles->size() * sizeof(int));

    cudaMemcpy(dev_triangles_parents, triangles_parents.data(), triangles->size() * sizeof(int),
                cudaMemcpyHostToDevice);
    timer->onTimer(TIMER_FACEGRAPH_GET_SETMENTS_A);
    // 각 삼각형에 대해서,
    for (int i = 0; i < triangles->size(); i++) {
        // 그 삼각형에 속한 정점과,
        for (int j = 0; j < 3; j++) {

            glm::vec3 vertex = triangles->at(i).vertex[j];

            size_t vertex_hash = vertex_hash_list[i].vertex[j];
            AdjacentNode* node = &adjacent_nodes[vertex_hash];

            int* adjacents = node->adjacents;
            // #pragma omp parallel for
            // for(int j = 0; j < node->filled_index; j++){
            //     Triangle tri_idx = triangles->at(i);
            //     Triangle tri_adj = triangles->at(adjacents[j]);
            //     if(triangles_parents[adjacents[j]] > triangles_parents[i])
            //         triangles_parents[adjacents[j]] = triangles_parents[i];
            // }
            cudaMemcpy(dev_adjacents, adjacents, node->filled_index * sizeof(int), cudaMemcpyHostToDevice);

            int grid_size = ceil(node->filled_index / BLOCK_SIZE);
            cuda_union_find<<<1, BLOCK_SIZE>>>(dev_triangles, i, dev_triangles_parents, dev_adjacents,
                                                 node->filled_index);
        }
    }
    cudaMemcpy(triangles_parents.data(), dev_triangles_parents, triangles->size() * sizeof(int),
                cudaMemcpyDeviceToHost);
    timer->offTimer(TIMER_FACEGRAPH_GET_SETMENTS_A);
    cudaFree(dev_triangles_parents);
    cudaFree(dev_adjacents);
    cudaFree(dev_triangles);

    delete[] vertex_hash_list;

    delete[] over_count_map;

    delete[] adjacent_nodes;

    destroy_locks(locks, vertex_size);
    timer->offTimer(TIMER_FACEGRAPH_INIT_B);
}
int value(int va) {
    return va;
}

std::vector<std::vector<Triangle>> CUDAFaceGraph::get_segments() {

    //  std::vector<int> is_visit(adj_triangles.size());
    // 방문했다면 정점이 속한 그룹의 카운트 + 1.

    /*int count = 0;
    for (int i = 0; i < adj_triangles.size(); i++) {
        if (is_visit[i] == 0) {
            traverse_dfs(is_visit, i, ++count);
        }
    }*/

    timer->onTimer(TIMER_FACEGRAPH_GET_SETMENTS_B);
    std::vector<std::vector<Triangle>> component_list(triangles->size());

    for (int i = 0; i < adj_triangles.size(); i++) {
        component_list[triangles_parents[i]].push_back(triangles->data()[i]);
    }

    timer->offTimer(TIMER_FACEGRAPH_GET_SETMENTS_B);

    return component_list;
}
/*
std::vector<std::vector<Triangle>> CUDAFaceGraph::get_segments() {
    timer->onTimer(TIMER_FACEGRAPH_GET_SETMENTS_A);

    timer->offTimer(TIMER_FACEGRAPH_GET_SETMENTS_A);

    timer->onTimer(TIMER_FACEGRAPH_GET_SETMENTS_B);
    std::vector<std::vector<Triangle>>component_list(triangles->size());
    omp_lock_t* locks = new_locks(triangles_parents.size());

    #pragma omp parallel for
    for(int i = 0; i < triangles_parents.size(); i++){
        omp_set_lock(&locks[i]);
        component_list[triangles_parents[i]].push_back(triangles->data()[i]);
        omp_unset_lock(&locks[i]);
    }

    timer->offTimer(TIMER_FACEGRAPH_GET_SETMENTS_B);
    destroy_locks(locks, triangles_parents.size());

    return component_list;
}*/

void CUDAFaceGraph::traverse_dfs(std::vector<int>& visit, int start_vert, int count) {
    std::stack<int> dfs_stack;
    dfs_stack.push(start_vert);

    while (!dfs_stack.empty()) {
        int current_vert = dfs_stack.top();
        dfs_stack.pop();

        visit[current_vert] = count;
        for (int i = 0; i < adj_triangles[current_vert].size(); i++) {
            int adjacent_triangle = adj_triangles[current_vert][i];
            if (visit[adjacent_triangle] == 0) {
                dfs_stack.push(adjacent_triangle);
            }
        }
    }
}
/*
void CUDAFaceGraph::union_find(std::vector<int>& visit, int start_vert, int count) {

    triangles_parents = std::vector<int>(triangles->size());

    //각 삼각형의 root를 자신으로 초기화
    #pragma omp parallel for
    for(int i = 0; i < triangles->size(); i++){
        triangles_parents[i] = i;
    }

    // 각 삼각형에 대해서,
    #pragma omp parallel for
    for (int i = 0; i < triangles->size(); i++) {
        // 그 삼각형에 속한 정점과,
        for (int j = 0; j < 3; j++) {
            glm::vec3 vertex = triangles->at(i).vertex[j];

            size_t vertex_hash = vertex_hash_list[i][j];
            AdjacentNode* node = &adjacent_nodes[vertex_hash];

            int* adjacents = node->adjacents;

            // 맞닿아 있는 삼각형이,
            for (int k = 0; k < node->filled_index; k++) {
                int adjacent_triangle = adjacents[k];
                // 자기 자신이 아니고,
                // 원래의 삼각형과도 맞닿아 있으면 루트를 원래의 삼각형으로 지정.
                if (i != adjacent_triangle && is_connected(triangles->at(i), triangles->at(adjacent_triangle))) {
                    if(triangles_parents[i] < triangles_parents[adjacent_triangle]){
                        triangles_parents[adjacent_triangle] = triangles_parents[i];
                    }
                }
            }
        }
    }
}*/
