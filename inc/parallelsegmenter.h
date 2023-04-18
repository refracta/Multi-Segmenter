﻿#ifndef __PARALLELSEGMENTER_H
#define __PARALLELSEGMENTER_H

#include "color.hpp"
#include "dstimer.h"
#include "facegraph.hpp"
#include "logutils.h"
#include "model.h"
#include "segmenter.hpp"
#include "trianglemesh.hpp"
#include <algorithm>
#include <chrono>
#include <glm/gtc/quaternion.hpp>
#include <glm/gtx/normal.hpp>
#include <glm/gtx/quaternion.hpp>
#include <glm/gtx/string_cast.hpp>
#include <glm/gtx/vector_angle.hpp>
#include <iostream>
#include <omp.h>
#include <stack>
#include <unordered_map>
#include <vector>

class ParallelSegmenter : public Segmenter {
  public:
    ParallelSegmenter(TriangleMesh* mesh, float tolerance = 0.0f);
    virtual std::vector<TriangleMesh*> do_segmentation();

  private:
    inline glm::vec3 get_normal_key(std::unordered_map<glm::vec3, size_t, Vec3Hash>& count_map, glm::vec3& normal);

    inline void init_count_map(std::unordered_map<glm::vec3, size_t, Vec3Hash>& count_map,
                               std::vector<glm::vec3>& face_normals);
};

#endif