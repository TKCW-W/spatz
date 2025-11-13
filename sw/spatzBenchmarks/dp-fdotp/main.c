// Copyright 2022 ETH Zurich and University of Bologna.
//
// SPDX-License-Identifier: Apache-2.0
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Author: Matteo Perotti <mperotti@iis.ee.ethz.ch>

#include <benchmark.h>
#include <debug.h>
#include <snrt.h>
#include <stdio.h>

#include DATAHEADER
#include "kernel/fdotp.c"

#define PADDING_ELEMENTS 0

double *a;
double *b;
double *c;
double *result;

static inline int fp_check(const double a, const double b) {
  const double threshold = 0.00001;

  // Absolute value
  double comp = a - b;
  if (comp < 0)
    comp = -comp;

  return comp > threshold;
}

int main() {
  const unsigned int num_cores = snrt_cluster_core_num(); // change to 1
  const unsigned int cid = snrt_cluster_core_idx();

  // Reset timer
  unsigned int timer = (unsigned int)-1;

  const unsigned int dim = dotp_l.M / num_cores; // remove /num_cores

  // Allocate the matrices
  if (cid == 0) {
    // a = (double *)snrt_l1alloc(dotp_l.M * sizeof(double));
    // b = (double *)snrt_l1alloc(dotp_l.M * sizeof(double));
    // result = (double *)snrt_l1alloc(num_cores * sizeof(double));
    const unsigned int total_elements = dotp_l.M + PADDING_ELEMENTS;
    a = (double *)snrt_l1alloc(total_elements * sizeof(double));
    //c = (double *)snrt_l1alloc(4 * sizeof(double));
    b = (double *)snrt_l1alloc(total_elements * sizeof(double));
    result = (double *)snrt_l1alloc(num_cores * sizeof(double));
  }

  // Initialize the matrices
  if (cid == 0) {
    // snrt_dma_start_1d(a, dotp_A_dram, dotp_l.M * sizeof(double));
    // snrt_dma_start_1d(b, dotp_B_dram, dotp_l.M * sizeof(double));
    // snrt_dma_wait_all();
    const unsigned int total_elements = dotp_l.M + PADDING_ELEMENTS;
    snrt_dma_start_1d(a, dotp_A_dram, total_elements * sizeof(double));
    snrt_dma_start_1d(b, dotp_B_dram, total_elements * sizeof(double));
    snrt_dma_wait_all();
  }

  // Wait for all cores to finish
  snrt_cluster_hw_barrier();

  // Calculate internal pointers
  //double *a_int = a + dim * cid;
  //double *b_int = b + dim * cid; // if cid == 1, shift by padding units 

  // data padding to shift cc1 address for misalignment
  double *a_int;
  double *b_int;

  if (cid == 1){
    a_int = a + dim * cid + PADDING_ELEMENTS;
    b_int = b + dim * cid + PADDING_ELEMENTS; 
  } else {
    a_int = a + dim * cid;
    b_int = b + dim * cid; 
  }

  // Wait for all cores to finish
  snrt_cluster_hw_barrier();

  // Start dump
  if (cid == 0)
    start_kernel();

  // Start timer
  if (cid == 0)
    timer = benchmark_get_cycle();

  // Calculate dotp
  double acc;
  acc = fdotp_v64b(a_int, b_int, dim);//QW
  result[cid] = acc;

  // Wait for all cores to finish
  snrt_cluster_hw_barrier();

  // Final reduction
  if (cid == 0) {
    for (unsigned int i = 1; i < num_cores; ++i)
      acc += result[i];
    result[0] = acc;
  }

  // Wait for all cores to finish
  snrt_cluster_hw_barrier();

  // End dump
  if (cid == 0)
    stop_kernel();

  // End timer and check if new best runtime
  if (cid == 0)
    timer = benchmark_get_cycle() - timer;

  // Check and display results
  if (cid == 0) {
    long unsigned int performance = 1000 * 2 * dotp_l.M / timer;
    long unsigned int utilization =
        performance / (2 * num_cores * SNRT_NFPU_PER_CORE);

    printf("\n----- (%d) dp fdotp -----\n", dotp_l.M);
    printf("The execution took %u cycles.\n", timer);
    printf("The performance is %ld OP/1000cycle (%ld%%o utilization).\n",
           performance, utilization);
  }

  if (cid == 0)
    if (fp_check(result[0], dotp_result)) {
      printf("Error: Result = %f, Golden = %f\n", result[0], dotp_result);
      return -1;
    }

  // Wait for core 0 to finish displaying results
  snrt_cluster_hw_barrier();

  return 0;
}

