/*
 *  TU Eindhoven
 *  Eindhoven, The Netherlands
 *
 *  Name            :   haar.cpp
 *
 *  Author          :   Francesco Comaschi (f.comaschi@tue.nl)
 *
 *  Date            :   November 12, 2012
 *
 *  Function        :   Haar features evaluation for face detection
 *
 *  History         :
 *      12-11-12    :   Initial version.
 *
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the
 * Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program;  If not, see <http://www.gnu.org/licenses/>
 *
 * In other words, you are welcome to use, share and improve this program.
 * You are forbidden to forbid anyone else to use, share and improve
 * what you give them.   Happy coding!
 */

#include "haar.h"
#include "image.h"
#include <stdio.h>
#include <stdint.h>
#include "stdio-wrapper.h"

/* include the gpu functions */
#include "haar_stage_kernel.cuh"

/* TODO: use matrices */
/* classifier parameters */
/************************************
 * Notes:
 * To paralleism the filter,
 * these monolithic arrays may
 * need to be splitted or duplicated
 ***********************************/
static int *stages_array;
static int *rectangles_array;
static int *weights_array;
static int *alpha1_array;
static int *alpha2_array;
static int *tree_thresh_array;
static int *stages_thresh_array;
static int **scaled_rectangles_array;

static int *hstages_array;
static uint16_t *hindex_x;
static uint16_t *hindex_y;
static uint16_t *hwidth;
static uint16_t *hheight;
static int16_t *hweights_array;
static int16_t *halpha1_array;
static int16_t *halpha2_array;
static int16_t *htree_thresh_array;
static int16_t *hstages_thresh_array;
static bool *bit_vector;

int clock_counter = 0;
float n_features = 0;


int iter_counter = 0;

/* compute integral images */
void integralImages( MyImage *src, MyIntImage *sum, MyIntImage *sqsum );

/* scale down the image */
void ScaleImage_Invoker( myCascade* _cascade, float _factor, int sum_row, int sum_col, std::vector<MyRect>& _vec);

/* compute scaled image */
void nearestNeighbor (MyImage *src, MyImage *dst);

/* rounding function */
inline  int  myRound( float value )
{
    return (int)(value + (value >= 0 ? 0.5 : -0.5));
}

/*******************************************************
 * Function: detectObjects
 * Description: It calls all the major steps
 ******************************************************/

std::vector<MyRect> detectObjects( MyImage* _img, MySize minSize, MySize maxSize, myCascade* cascade,
        float scaleFactor, int minNeighbors)
{

    /* group overlaping windows */
    const float GROUP_EPS = 0.4f;
    /* pointer to input image */
    MyImage *img = _img;
    /***********************************
     * create structs for images
     * see haar.h for details 
     * img1: normal image (unsigned char)
     * sum1: integral image (int)
     * sqsum1: square integral image (int)
     **********************************/
    MyImage image1Obj;
    MyIntImage sum1Obj;
    MyIntImage sqsum1Obj;

    /* pointers for the created structs */
    MyImage *img1 = &image1Obj;
    MyIntImage *sum1 = &sum1Obj;
    MyIntImage *sqsum1 = &sqsum1Obj;

    /********************************************************
     * allCandidates is the preliminaray face candidate,
     * which will be refined later.
     *
     * std::vector is a sequential container 
     * http://en.wikipedia.org/wiki/Sequence_container_(C++) 
     *
     * Each element of the std::vector is a "MyRect" struct 
     * MyRect struct keeps the info of a rectangle (see haar.h)
     * The rectangle contains one face candidate 
     *****************************************************/
    std::vector<MyRect> allCandidates;
    std::vector<MyRect> faces; // For data from GPU

    /* scaling factor */
    float factor;

    /* maxSize */
    if( maxSize.height == 0 || maxSize.width == 0 )
    {
        maxSize.height = img->height;
        maxSize.width = img->width;
    }

    /* window size of the training set */
    MySize winSize0 = cascade->orig_window_size;

    /* malloc for img1: unsigned char */
    createImage(img->width, img->height, img1);
    /* malloc for sum1: unsigned char */
    createSumImage(img->width, img->height, sum1);
    /* malloc for sqsum1: unsigned char */
    createSumImage(img->width, img->height, sqsum1);

    /****************************************************
      Setting up the data for GPU Kernels
     ***************************************************/

    uint16_t* dindex_x;
    uint16_t* dindex_y;
    uint16_t* dwidth;
    uint16_t* dheight;
    int16_t* dweights_array;
    int16_t* dalpha1_array;
    int16_t* dalpha2_array;
    int16_t* dtree_thresh_array;
    int16_t* dstages_thresh_array;
    int32_t* dsum;
    int32_t* dsqsum; 
    int* dhaar_per_stg;
    bool* dbit_vector;

    bit_vector = (bool*) malloc(img->width*img->height*sizeof(bool));

    cudaMalloc(&dindex_x, 3*TOTAL_HAAR*sizeof(uint16_t));
    checkError();
    cudaMalloc(&dindex_y, 3*TOTAL_HAAR*sizeof(uint16_t));
    checkError();
    cudaMalloc(&dwidth, 3*TOTAL_HAAR*sizeof(uint16_t));
    checkError();
    cudaMalloc(&dheight, 3*TOTAL_HAAR*sizeof(uint16_t));
    checkError();

    cudaMalloc(&dweights_array, 3*TOTAL_HAAR*sizeof(int16_t));
    checkError();
    cudaMalloc(&dtree_thresh_array, TOTAL_HAAR*sizeof(int16_t));
    checkError();
    cudaMalloc(&dalpha1_array, TOTAL_HAAR*sizeof(int16_t));
    checkError();
    cudaMalloc(&dalpha2_array, TOTAL_HAAR*sizeof(int16_t));
    checkError();
    cudaMalloc(&dstages_thresh_array, TOTAL_STAGES*sizeof(int16_t));
    checkError();
    cudaMalloc(&dhaar_per_stg, TOTAL_STAGES*sizeof(int));
    checkError();

    cudaMemcpy(dindex_x, hindex_x, 3*TOTAL_HAAR*sizeof(uint16_t), cudaMemcpyHostToDevice);
    checkError();
    cudaMemcpy(dindex_y, hindex_y, 3*TOTAL_HAAR*sizeof(uint16_t), cudaMemcpyHostToDevice);
    checkError();
    cudaMemcpy(dwidth, hwidth, 3*TOTAL_HAAR*sizeof(uint16_t), cudaMemcpyHostToDevice);
    checkError();
    cudaMemcpy(dheight, hheight, 3*TOTAL_HAAR*sizeof(uint16_t), cudaMemcpyHostToDevice);
    checkError();

    cudaMemcpy(dweights_array, hweights_array, 3*TOTAL_HAAR*sizeof(int16_t), cudaMemcpyHostToDevice);
    checkError();
    cudaMemcpy(dtree_thresh_array, htree_thresh_array, TOTAL_HAAR*sizeof(int16_t), cudaMemcpyHostToDevice);
    checkError();
    cudaMemcpy(dalpha1_array, halpha1_array, TOTAL_HAAR*sizeof(int16_t), cudaMemcpyHostToDevice);
    checkError();
    cudaMemcpy(dalpha2_array, halpha2_array, TOTAL_HAAR*sizeof(int16_t), cudaMemcpyHostToDevice);
    checkError();
    cudaMemcpy(dstages_thresh_array, hstages_thresh_array, TOTAL_STAGES*sizeof(int16_t), cudaMemcpyHostToDevice);
    checkError();
    cudaMemcpy(dhaar_per_stg, hstages_array, TOTAL_STAGES*sizeof(int), cudaMemcpyHostToDevice);
    checkError();

    /*
    for(int i =0; i<3*TOTAL_HAAR; i++) {
        printf("Weight[%d] = %d\n", i, hweights_array[i]);
    }
    printf("-------------------------\n");
    */

    /* initial scaling factor */
    factor = 1;

    float gpu_all_stages = 0.0f;
    /* iterate over the image pyramid */
    for( factor = 1; ; factor *= scaleFactor )
    {
        /* iteration counter */
        iter_counter++;

        /* size of the image scaled up */
        MySize winSize = { myRound(winSize0.width*factor), myRound(winSize0.height*factor) };

        /* size of the image scaled down (from bigger to smaller) */
        MySize sz = { ( img->width/factor ), ( img->height/factor ) };

        /* difference between sizes of the scaled image and the original detection window */
        MySize sz1 = { sz.width - winSize0.width, sz.height - winSize0.height };

        /* if the actual scaled image is smaller than the original detection window, break */
        if( sz1.width < 0 || sz1.height < 0 )
            break;

        /* if a minSize different from the original detection window is specified, continue to the next scaling */
        if( winSize.width < minSize.width || winSize.height < minSize.height )
            continue;

        /*************************************
         * Set the width and height of 
         * img1: normal image (unsigned char)
         * sum1: integral image (int)
         * sqsum1: squared integral image (int)
         * see image.c for details
         ************************************/
        setImage(sz.width, sz.height, img1);
        setSumImage(sz.width, sz.height, sum1);
        setSumImage(sz.width, sz.height, sqsum1);

        /***************************************
         * Compute-intensive step:
         * building image pyramid by downsampling
         * downsampling using nearest neighbor
         **************************************/
        nearestNeighbor(img, img1);

        /***************************************************
         * Compute-intensive step:
         * At each scale of the image pyramid,
         * compute a new integral and squared integral image
         ***************************************************/
        integralImages(img1, sum1, sqsum1);

        /* sets images for haar classifier cascade */
        /**************************************************
         * Note:
         * Summing pixels within a haar window is done by
         * using four corners of the integral image:
         * http://en.wikipedia.org/wiki/Summed_area_table
         * 
         * This function loads the four corners,
         * but does not do compuation based on four coners.
         * The computation is done next in ScaleImage_Invoker
         *************************************************/
        printf("detecting faces, iter := %d\n", iter_counter);

        /*-------------------------------------------------------------------
          Starting timer for Runcascade Kernels comparison
          -------------------------------------------------------------------*/
        // Calculate CPU time
        cudaEvent_t startEvent_cpu, stopEvent_cpu;
        cudaEventCreate(&startEvent_cpu);
        cudaEventCreate(&stopEvent_cpu);
        float elapsedTime_cpu;

        // Starting the timer
        cudaEventRecord(startEvent_cpu, 0);

        setImageForCascadeClassifier(cascade, sum1, sqsum1);

        /* print out for each scale of the image pyramid */

        /****************************************************
         * Process the current scale with the cascaded fitler.
         * The main computations are invoked by this function.
         * Optimization oppurtunity:
         * the same cascade filter is invoked each time
         ***************************************************/
        ScaleImage_Invoker(cascade, factor, sum1->height, sum1->width,
                allCandidates);
        cudaEventRecord(stopEvent_cpu, 0);
        cudaEventSynchronize(stopEvent_cpu);
        // Stopping the timer

        cudaEventElapsedTime(&elapsedTime_cpu, startEvent_cpu, stopEvent_cpu);
        /*--------------------------------------------------------------------------------------------*/

        printf("Event:Time for CPU to complete execution: %f ms\n", elapsedTime_cpu);

        int bitvec_width = img1->width-cascade->orig_window_size.width;
        int bitvec_height = img1->height-cascade->orig_window_size.height;

        /*
           printf("Within detect objects. Size of result = %d\n", allCandidates.size());
           printf("Done with ScaleImage Invoker\n");
           fflush(stdout);
         */
        /****************************************************
          Setting up the data for GPU Kernels
         ***************************************************/
        cudaMalloc(&dsum, img1->width*img1->height*sizeof(int32_t));
        checkError();
        cudaMalloc(&dsqsum, img1->width*img1->height*sizeof(int32_t));
        checkError();
        cudaMalloc(&dbit_vector, bitvec_width*bitvec_height*sizeof(bool));
        checkError();
        bool* hbit_vector = (bool*) malloc(bitvec_width*bitvec_height*sizeof(bool));

        int i;
        for(i=0; i<(bitvec_width*bitvec_height); i++) {
            hbit_vector[i] = true;
        }
        cudaMemcpy(dsum, sum1->data, sum1->width*sum1->height*sizeof(int32_t), cudaMemcpyHostToDevice);
        checkError();
        cudaMemcpy(dsqsum, sqsum1->data, sqsum1->width*sqsum1->height*sizeof(int32_t), cudaMemcpyHostToDevice);
        checkError();
        cudaMemcpy(dbit_vector, hbit_vector, bitvec_width*bitvec_height*sizeof(bool), cudaMemcpyHostToDevice);
        checkError();
        // Kernel 0
        dim3 numThreads(32, 32);
        dim3 numBlocks((bitvec_width+31)/32, (bitvec_height+31)/32);

        printf("Entering kernel\n");
        cudaFuncSetCacheConfig(haar_stage_kernel0, cudaFuncCachePreferShared);
        checkError();
        /*-------------------------------------------------------------------
          Starting timer for Runcascade Kernels comparison
          -------------------------------------------------------------------*/
        // Calculate GPU time
        cudaEvent_t startEvent_gpu, stopEvent_gpu;
        cudaEventCreate(&startEvent_gpu);
        cudaEventCreate(&stopEvent_gpu);

        float elapsedTime_gpu, gpu_total_time = 0.0f;
        
        // Starting the timer
        cudaEventRecord(startEvent_gpu, 0);

        haar_stage_kernel0<<<numBlocks, numThreads>>>(dindex_x, dindex_y, dwidth, dheight, 
                dweights_array, dtree_thresh_array, dalpha1_array, dalpha2_array, 
                dstages_thresh_array, dsum, dsqsum, dhaar_per_stg, HAAR_KERN_0, 
                NUMSTG_KERN_0, img1->width, img1->height, dbit_vector); 
        checkError();

        cudaEventRecord(stopEvent_gpu, 0);
        cudaEventSynchronize(stopEvent_gpu);
        // Stopping the timer

        cudaEventElapsedTime(&elapsedTime_gpu, startEvent_gpu, stopEvent_gpu);

        printf("\tCC: Kernel 1 Complete--> Exclusive Time: %f ms\n", elapsedTime_gpu);
        gpu_total_time += elapsedTime_gpu;
        /*--------------------------------------------------------------------------------------------*/

        cudaDeviceSynchronize();
        checkError();

        int haar_prev_stage = HAAR_KERN_0;
        int num_prev_stage = NUMSTG_KERN_0;

        // Starting the timer
        cudaEventRecord(startEvent_gpu, 0);

        haar_stage_kernel0<<<numBlocks, numThreads>>>(dindex_x+3*haar_prev_stage, dindex_y+3*haar_prev_stage, 
                dwidth+3*haar_prev_stage, dheight+3*haar_prev_stage, dweights_array+3*haar_prev_stage, 
                dtree_thresh_array+haar_prev_stage, dalpha1_array+haar_prev_stage, 
                dalpha2_array+haar_prev_stage, dstages_thresh_array+num_prev_stage, dsum, dsqsum, 
                dhaar_per_stg+num_prev_stage, HAAR_KERN_1, NUMSTG_KERN_1, 
                img1->width, img1->height, dbit_vector); 
        checkError();

        cudaDeviceSynchronize();
        checkError();

        cudaEventRecord(stopEvent_gpu, 0);
        cudaEventSynchronize(stopEvent_gpu);
        // Stopping the timer

        cudaEventElapsedTime(&elapsedTime_gpu, startEvent_gpu, stopEvent_gpu);

        printf("\tCC: Kernel 2 Complete--> Exclusive Time: %f ms\n", elapsedTime_gpu);
        gpu_total_time += elapsedTime_gpu;
        /*--------------------------------------------------------------------------------------------*/

        haar_prev_stage += HAAR_KERN_1;
        num_prev_stage += NUMSTG_KERN_1;
        
        // Starting the timer
        cudaEventRecord(startEvent_gpu, 0);

        haar_stage_kernel0<<<numBlocks, numThreads>>>(dindex_x+3*haar_prev_stage, dindex_y+3*haar_prev_stage, 
                dwidth+3*haar_prev_stage, dheight+3*haar_prev_stage, dweights_array+3*haar_prev_stage, 
                dtree_thresh_array+haar_prev_stage, dalpha1_array+haar_prev_stage, 
                dalpha2_array+haar_prev_stage, dstages_thresh_array+num_prev_stage, dsum, dsqsum, 
                dhaar_per_stg+num_prev_stage, HAAR_KERN_2, NUMSTG_KERN_2, 
                img1->width, img1->height, dbit_vector); 
        checkError();

        cudaDeviceSynchronize();
        checkError();

        cudaEventRecord(stopEvent_gpu, 0);
        cudaEventSynchronize(stopEvent_gpu);
        // Stopping the timer

        cudaEventElapsedTime(&elapsedTime_gpu, startEvent_gpu, stopEvent_gpu);

        printf("\tCC: Kernel 3 Complete--> Exclusive Time: %f ms\n", elapsedTime_gpu);
        gpu_total_time += elapsedTime_gpu;
        /*--------------------------------------------------------------------------------------------*/

        haar_prev_stage += HAAR_KERN_2;
        num_prev_stage += NUMSTG_KERN_2;
        
        // Starting the timer
        cudaEventRecord(startEvent_gpu, 0);

        haar_stage_kernel0<<<numBlocks, numThreads>>>(dindex_x+3*haar_prev_stage, dindex_y+3*haar_prev_stage, 
                dwidth+3*haar_prev_stage, dheight+3*haar_prev_stage, dweights_array+3*haar_prev_stage, 
                dtree_thresh_array+haar_prev_stage, dalpha1_array+haar_prev_stage, 
                dalpha2_array+haar_prev_stage, dstages_thresh_array+num_prev_stage, dsum, dsqsum, 
                dhaar_per_stg+num_prev_stage, HAAR_KERN_3, NUMSTG_KERN_3, 
                img1->width, img1->height, dbit_vector); 
        checkError();

        cudaDeviceSynchronize();
        checkError();

        cudaEventRecord(stopEvent_gpu, 0);
        cudaEventSynchronize(stopEvent_gpu);
        // Stopping the timer

        cudaEventElapsedTime(&elapsedTime_gpu, startEvent_gpu, stopEvent_gpu);

        printf("\tCC: Kernel 4 Complete--> Exclusive Time: %f ms\n", elapsedTime_gpu);
        gpu_total_time += elapsedTime_gpu;
        /*--------------------------------------------------------------------------------------------*/

        haar_prev_stage += HAAR_KERN_3;
        num_prev_stage += NUMSTG_KERN_3;
        
        // Starting the timer
        cudaEventRecord(startEvent_gpu, 0);

        haar_stage_kernel0<<<numBlocks, numThreads>>>(dindex_x+3*haar_prev_stage, dindex_y+3*haar_prev_stage, 
                dwidth+3*haar_prev_stage, dheight+3*haar_prev_stage, dweights_array+3*haar_prev_stage, 
                dtree_thresh_array+haar_prev_stage, dalpha1_array+haar_prev_stage, 
                dalpha2_array+haar_prev_stage, dstages_thresh_array+num_prev_stage, dsum, dsqsum, 
                dhaar_per_stg+num_prev_stage, HAAR_KERN_4, NUMSTG_KERN_4, 
                img1->width, img1->height, dbit_vector); 
        checkError();

        cudaDeviceSynchronize();
        checkError();

        cudaEventRecord(stopEvent_gpu, 0);
        cudaEventSynchronize(stopEvent_gpu);
        // Stopping the timer

        cudaEventElapsedTime(&elapsedTime_gpu, startEvent_gpu, stopEvent_gpu);

        printf("\tCC: Kernel 5 Complete--> Exclusive Time: %f ms\n", elapsedTime_gpu);
        gpu_total_time += elapsedTime_gpu;
        /*--------------------------------------------------------------------------------------------*/

        haar_prev_stage += HAAR_KERN_4;
        num_prev_stage += NUMSTG_KERN_4;
        
        // Starting the timer
        cudaEventRecord(startEvent_gpu, 0);

        haar_stage_kernel0<<<numBlocks, numThreads>>>(dindex_x+3*haar_prev_stage, dindex_y+3*haar_prev_stage, 
                dwidth+3*haar_prev_stage, dheight+3*haar_prev_stage, dweights_array+3*haar_prev_stage, 
                dtree_thresh_array+haar_prev_stage, dalpha1_array+haar_prev_stage, 
                dalpha2_array+haar_prev_stage, dstages_thresh_array+num_prev_stage, dsum, dsqsum, 
                dhaar_per_stg+num_prev_stage, HAAR_KERN_5, NUMSTG_KERN_5, 
                img1->width, img1->height, dbit_vector); 
        checkError();

        cudaDeviceSynchronize();
        checkError();

        cudaEventRecord(stopEvent_gpu, 0);
        cudaEventSynchronize(stopEvent_gpu);
        // Stopping the timer

        cudaEventElapsedTime(&elapsedTime_gpu, startEvent_gpu, stopEvent_gpu);

        printf("\tCC: Kernel 6 Complete--> Exclusive Time: %f ms\n", elapsedTime_gpu);
        gpu_total_time += elapsedTime_gpu;
        /*--------------------------------------------------------------------------------------------*/

        haar_prev_stage += HAAR_KERN_5;
        num_prev_stage += NUMSTG_KERN_5;
        
        // Starting the timer
        cudaEventRecord(startEvent_gpu, 0);

        haar_stage_kernel0<<<numBlocks, numThreads>>>(dindex_x+3*haar_prev_stage, dindex_y+3*haar_prev_stage, 
                dwidth+3*haar_prev_stage, dheight+3*haar_prev_stage, dweights_array+3*haar_prev_stage, 
                dtree_thresh_array+haar_prev_stage, dalpha1_array+haar_prev_stage, 
                dalpha2_array+haar_prev_stage, dstages_thresh_array+num_prev_stage, dsum, dsqsum, 
                dhaar_per_stg+num_prev_stage, HAAR_KERN_6, NUMSTG_KERN_6, 
                img1->width, img1->height, dbit_vector); 
        checkError();

        cudaDeviceSynchronize();
        checkError();

        cudaEventRecord(stopEvent_gpu, 0);
        cudaEventSynchronize(stopEvent_gpu);
        // Stopping the timer

        cudaEventElapsedTime(&elapsedTime_gpu, startEvent_gpu, stopEvent_gpu);

        printf("\tCC: Kernel 7 Complete--> Exclusive Time: %f ms\n", elapsedTime_gpu);
        gpu_total_time += elapsedTime_gpu;
        /*--------------------------------------------------------------------------------------------*/

        haar_prev_stage += HAAR_KERN_6;
        num_prev_stage += NUMSTG_KERN_6;
        
        // Starting the timer
        cudaEventRecord(startEvent_gpu, 0);

        haar_stage_kernel0<<<numBlocks, numThreads>>>(dindex_x+3*haar_prev_stage, dindex_y+3*haar_prev_stage, 
                dwidth+3*haar_prev_stage, dheight+3*haar_prev_stage, dweights_array+3*haar_prev_stage, 
                dtree_thresh_array+haar_prev_stage, dalpha1_array+haar_prev_stage, 
                dalpha2_array+haar_prev_stage, dstages_thresh_array+num_prev_stage, dsum, dsqsum, 
                dhaar_per_stg+num_prev_stage, HAAR_KERN_7, NUMSTG_KERN_7, 
                img1->width, img1->height, dbit_vector); 
        checkError();

        cudaDeviceSynchronize();
        checkError();

        cudaEventRecord(stopEvent_gpu, 0);
        cudaEventSynchronize(stopEvent_gpu);
        // Stopping the timer

        cudaEventElapsedTime(&elapsedTime_gpu, startEvent_gpu, stopEvent_gpu);

        printf("\tCC: Kernel 8 Complete--> Exclusive Time: %f ms\n", elapsedTime_gpu);
        gpu_total_time += elapsedTime_gpu;
        /*--------------------------------------------------------------------------------------------*/

        haar_prev_stage += HAAR_KERN_7;
        num_prev_stage += NUMSTG_KERN_7;
        
        // Starting the timer
        cudaEventRecord(startEvent_gpu, 0);

        haar_stage_kernel0<<<numBlocks, numThreads>>>(dindex_x+3*haar_prev_stage, dindex_y+3*haar_prev_stage, 
                dwidth+3*haar_prev_stage, dheight+3*haar_prev_stage, dweights_array+3*haar_prev_stage, 
                dtree_thresh_array+haar_prev_stage, dalpha1_array+haar_prev_stage, 
                dalpha2_array+haar_prev_stage, dstages_thresh_array+num_prev_stage, dsum, dsqsum, 
                dhaar_per_stg+num_prev_stage, HAAR_KERN_8, NUMSTG_KERN_8, 
                img1->width, img1->height, dbit_vector); 
        checkError();

        cudaDeviceSynchronize();
        checkError();

        cudaEventRecord(stopEvent_gpu, 0);
        cudaEventSynchronize(stopEvent_gpu);
        // Stopping the timer

        cudaEventElapsedTime(&elapsedTime_gpu, startEvent_gpu, stopEvent_gpu);

        printf("\tCC: Kernel 9 Complete--> Exclusive Time: %f ms\n", elapsedTime_gpu);
        gpu_total_time += elapsedTime_gpu;
        /*--------------------------------------------------------------------------------------------*/

        haar_prev_stage += HAAR_KERN_8;
        num_prev_stage += NUMSTG_KERN_8;
        
        // Starting the timer
        cudaEventRecord(startEvent_gpu, 0);

        haar_stage_kernel0<<<numBlocks, numThreads>>>(dindex_x+3*haar_prev_stage, dindex_y+3*haar_prev_stage, 
                dwidth+3*haar_prev_stage, dheight+3*haar_prev_stage, dweights_array+3*haar_prev_stage, 
                dtree_thresh_array+haar_prev_stage, dalpha1_array+haar_prev_stage, 
                dalpha2_array+haar_prev_stage, dstages_thresh_array+num_prev_stage, dsum, dsqsum, 
                dhaar_per_stg+num_prev_stage, HAAR_KERN_9, NUMSTG_KERN_9, 
                img1->width, img1->height, dbit_vector); 
        checkError();

        cudaDeviceSynchronize();
        checkError();

        cudaEventRecord(stopEvent_gpu, 0);
        cudaEventSynchronize(stopEvent_gpu);
        // Stopping the timer

        cudaEventElapsedTime(&elapsedTime_gpu, startEvent_gpu, stopEvent_gpu);

        printf("\tCC: Kernel 10 Complete--> Exclusive Time: %f ms\n", elapsedTime_gpu);
        gpu_total_time += elapsedTime_gpu;
        /*--------------------------------------------------------------------------------------------*/

        haar_prev_stage += HAAR_KERN_9;
        num_prev_stage += NUMSTG_KERN_9;
        
        // Starting the timer
        cudaEventRecord(startEvent_gpu, 0);

        haar_stage_kernel0<<<numBlocks, numThreads>>>(dindex_x+3*haar_prev_stage, dindex_y+3*haar_prev_stage, 
                dwidth+3*haar_prev_stage, dheight+3*haar_prev_stage, dweights_array+3*haar_prev_stage, 
                dtree_thresh_array+haar_prev_stage, dalpha1_array+haar_prev_stage, 
                dalpha2_array+haar_prev_stage, dstages_thresh_array+num_prev_stage, dsum, dsqsum, 
                dhaar_per_stg+num_prev_stage, HAAR_KERN_10, NUMSTG_KERN_10, 
                img1->width, img1->height, dbit_vector); 
        checkError();

        cudaDeviceSynchronize();
        checkError();

        cudaEventRecord(stopEvent_gpu, 0);
        cudaEventSynchronize(stopEvent_gpu);
        // Stopping the timer

        cudaEventElapsedTime(&elapsedTime_gpu, startEvent_gpu, stopEvent_gpu);

        printf("\tCC: Kernel 11 Complete--> Exclusive Time: %f ms\n", elapsedTime_gpu);
        gpu_total_time += elapsedTime_gpu;
        /*--------------------------------------------------------------------------------------------*/

        haar_prev_stage += HAAR_KERN_10;
        num_prev_stage += NUMSTG_KERN_10;
        
        // Starting the timer
        cudaEventRecord(startEvent_gpu, 0);

        haar_stage_kernel0<<<numBlocks, numThreads>>>(dindex_x+3*haar_prev_stage, dindex_y+3*haar_prev_stage, 
                dwidth+3*haar_prev_stage, dheight+3*haar_prev_stage, dweights_array+3*haar_prev_stage, 
                dtree_thresh_array+haar_prev_stage, dalpha1_array+haar_prev_stage, 
                dalpha2_array+haar_prev_stage, dstages_thresh_array+num_prev_stage, dsum, dsqsum, 
                dhaar_per_stg+num_prev_stage, HAAR_KERN_11, NUMSTG_KERN_11, 
                img1->width, img1->height, dbit_vector); 
        checkError();
        cudaMemcpy(hbit_vector, dbit_vector, bitvec_width*bitvec_height*sizeof(bool), cudaMemcpyDeviceToHost);
        checkError();

        cudaDeviceSynchronize();
        checkError();

        cudaEventRecord(stopEvent_gpu, 0);
        cudaEventSynchronize(stopEvent_gpu);
        // Stopping the timer

        cudaEventElapsedTime(&elapsedTime_gpu, startEvent_gpu, stopEvent_gpu);

        printf("\tCC: Kernel 12 Complete--> Exclusive Time: %f ms\n", elapsedTime_gpu);
        gpu_total_time += elapsedTime_gpu;
        gpu_all_stages += gpu_total_time;
        /***********************************************************************************/
        printf("\tCascade Classifier on GPU Complete--> Combined Exclusive Time: %f ms\n\n", gpu_total_time);
        printf("--------------------------------------------------------------------------------------------------\n\n");

        int x, y;
        for(y=0; y<bitvec_height; y++) {
            for(x=0; x<bitvec_width; x++) {
                if(hbit_vector[y*bitvec_width+x] == true) {
                    MyRect r = {myRound(x*factor), myRound(y*factor), winSize.width, winSize.height};
                    faces.push_back(r);
                }
            }
        }
       
        /*
        cudaEventRecord(stopEvent_gpu, 0);
        cudaEventSynchronize(stopEvent_gpu);
        // Stopping the timer

        float elapsedTime_gpu;
        cudaEventElapsedTime(&elapsedTime_gpu, startEvent_gpu, stopEvent_gpu); */
        /*--------------------------------------------------------------------------------------------*/

        //printf("Event:Time for GPU to complete execution: %f ms\n", elapsedTime_gpu);

        //printf("GPU data: Factor = %f: Number of faces = %d\n----------------------------------------\n", factor, faces.size());
        
        cudaFree(dsum);
        cudaFree(dsqsum);
        cudaFree(dbit_vector);
        free(hbit_vector);

    } /* end of the factor loop, finish all scales in pyramid*/

    printf("Face detection of all iterations on GPU Complete--> Combined Exclusive Time: %f ms\n\n", gpu_all_stages);
    cudaFree(dindex_x);
    cudaFree(dindex_y);
    cudaFree(dwidth);
    cudaFree(dheight);
    cudaFree(dweights_array);
    cudaFree(dalpha1_array);
    cudaFree(dalpha2_array);
    cudaFree(dtree_thresh_array);
    cudaFree(dstages_thresh_array);
    //cudaFree(dsum);
    //cudaFree(dsqsum); 
    cudaFree(dhaar_per_stg);

    if( minNeighbors != 0)
    {
        //groupRectangles(allCandidates, minNeighbors, GROUP_EPS);
        groupRectangles(faces, minNeighbors, GROUP_EPS);
    }

    printf("GPU data: Number of faces = %d\n", faces.size());
    freeImage(img1);
    freeSumImage(sum1);
    freeSumImage(sqsum1);
    //return allCandidates;
    return faces;

}

void checkError() {
    // check for error
    cudaError_t error = cudaGetLastError();
    if(error != cudaSuccess)
    {
        // print the CUDA error message and exit
        printf("CUDA error: %s\n", cudaGetErrorString(error));
        exit(EXIT_FAILURE);
    }
}

void compare_bits(bool* ref, bool* data, int n) {
    int i;
    int counter = 0;
    for(i=0; i<n; i++) {
        if(ref[i] == true) {
            printf("True: %d = %d\n", ref[i], data[i]);
        }
        if(ref[i] != data[i]) {
            printf("%d: Failed: %d != %d\n", i, ref[i], data[i]);
            counter++;
        }
    }
    if(counter == 0) {
        printf("Test Passed\n-----------------------------------------------------\n");
    }
}


/***********************************************
 * Note:
 * The int_sqrt is softwar integer squre root.
 * GPU has hardware for floating squre root (sqrtf).
 * In GPU, it is wise to convert an int variable
 * into floating point, and use HW sqrtf function.
 * More info:
 * http://docs.nvidia.com/cuda/cuda-c-programming-guide/index.html#standard-functions
 **********************************************/
/*****************************************************
 * The int_sqrt is only used in runCascadeClassifier
 * If you want to replace int_sqrt with HW sqrtf in GPU,
 * simple look into the runCascadeClassifier function.
 *****************************************************/
unsigned int int_sqrt (unsigned int value)
{
    int i;
    unsigned int a = 0, b = 0, c = 0;
    for (i=0; i < (32 >> 1); i++)
    {
        c<<= 2;
#define UPPERBITS(value) (value>>30)
        c += UPPERBITS(value);
#undef UPPERBITS
        value <<= 2;
        a <<= 1;
        b = (a<<1) | 1;
        if (c >= b)
        {
            c -= b;
            a++;
        }
    }
    return a;
}


void setImageForCascadeClassifier( myCascade* _cascade, MyIntImage* _sum, MyIntImage* _sqsum)
{
    MyIntImage *sum = _sum;
    MyIntImage *sqsum = _sqsum;
    myCascade* cascade = _cascade;
    int i, j, k;
    MyRect equRect;
    int r_index = 0;
    int w_index = 0;
    MyRect tr;

    cascade->sum = *sum;
    cascade->sqsum = *sqsum;

    equRect.x = equRect.y = 0;
    equRect.width = cascade->orig_window_size.width;
    equRect.height = cascade->orig_window_size.height;

    cascade->inv_window_area = equRect.width*equRect.height;

    cascade->p0 = (sum->data) ;
    cascade->p1 = (sum->data +  equRect.width - 1) ;
    cascade->p2 = (sum->data + sum->width*(equRect.height - 1));
    cascade->p3 = (sum->data + sum->width*(equRect.height - 1) + equRect.width - 1);
    cascade->pq0 = (sqsum->data);
    cascade->pq1 = (sqsum->data +  equRect.width - 1) ;
    cascade->pq2 = (sqsum->data + sqsum->width*(equRect.height - 1));
    cascade->pq3 = (sqsum->data + sqsum->width*(equRect.height - 1) + equRect.width - 1);

    /****************************************
     * Load the index of the four corners 
     * of the filter rectangle
     **************************************/

    /* loop over the number of stages */
    for( i = 0; i < cascade->n_stages; i++ )
    {
        /* loop over the number of haar features */
        for( j = 0; j < stages_array[i]; j++ )
        {
            int nr = 3;
            /* loop over the number of rectangles */
            for( k = 0; k < nr; k++ )
            {
                tr.x = rectangles_array[r_index + k*4];
                tr.width = rectangles_array[r_index + 2 + k*4];
                tr.y = rectangles_array[r_index + 1 + k*4];
                tr.height = rectangles_array[r_index + 3 + k*4];

                if (k < 2)
                {
                    scaled_rectangles_array[r_index + k*4] = (sum->data + sum->width*(tr.y ) + (tr.x )) ;
                    scaled_rectangles_array[r_index + k*4 + 1] = (sum->data + sum->width*(tr.y ) + (tr.x  + tr.width)) ;
                    scaled_rectangles_array[r_index + k*4 + 2] = (sum->data + sum->width*(tr.y  + tr.height) + (tr.x ));
                    scaled_rectangles_array[r_index + k*4 + 3] = (sum->data + sum->width*(tr.y  + tr.height) + (tr.x  + tr.width));
                }
                else   //for 3rd rect
                {
                    if ((tr.x == 0)&& (tr.y == 0) &&(tr.width == 0) &&(tr.height == 0))
                    {
                        scaled_rectangles_array[r_index + k*4] = NULL ;
                        scaled_rectangles_array[r_index + k*4 + 1] = NULL ;
                        scaled_rectangles_array[r_index + k*4 + 2] = NULL;
                        scaled_rectangles_array[r_index + k*4 + 3] = NULL;
                    }
                    else
                    {
                        scaled_rectangles_array[r_index + k*4] = (sum->data + sum->width*(tr.y ) + (tr.x )) ;
                        scaled_rectangles_array[r_index + k*4 + 1] = (sum->data + sum->width*(tr.y ) + (tr.x  + tr.width)) ;
                        scaled_rectangles_array[r_index + k*4 + 2] = (sum->data + sum->width*(tr.y  + tr.height) + (tr.x ));
                        scaled_rectangles_array[r_index + k*4 + 3] = (sum->data + sum->width*(tr.y  + tr.height) + (tr.x  + tr.width));
                    }
                } /* end of branch if(k<2) */
            } /* end of k loop*/

            r_index+=12;
            w_index+=3;

        } /* end of j loop */
    } /* end i loop */
}


/****************************************************
 * evalWeakClassifier:
 * the actual computation of a haar filter.
 * More info:
 * http://en.wikipedia.org/wiki/Haar-like_features
 ***************************************************/
inline int evalWeakClassifier(int variance_norm_factor, int p_offset, int tree_index, int w_index, int r_index )
{

    /* the node threshold is multiplied by the standard deviation of the image */
    int t = tree_thresh_array[tree_index] * variance_norm_factor;               //Filter threshold

    int sum = (*(scaled_rectangles_array[r_index] + p_offset)
            - *(scaled_rectangles_array[r_index + 1] + p_offset)
            - *(scaled_rectangles_array[r_index + 2] + p_offset)
            + *(scaled_rectangles_array[r_index + 3] + p_offset))
        * weights_array[w_index];

    /* 
       if(p_offset == 648) {
       printf("CPU: %d - %d - %d + %d = %d\nweight0 = %d, sum = %d\n", *(scaled_rectangles_array[r_index] + p_offset),
     *(scaled_rectangles_array[r_index+1] + p_offset),
     *(scaled_rectangles_array[r_index+2] + p_offset),
     *(scaled_rectangles_array[r_index+3] + p_offset), sum, weights_array[w_index], sum);
     }*/

    sum += (*(scaled_rectangles_array[r_index+4] + p_offset)
            - *(scaled_rectangles_array[r_index + 5] + p_offset)
            - *(scaled_rectangles_array[r_index + 6] + p_offset)
            + *(scaled_rectangles_array[r_index + 7] + p_offset))
        * weights_array[w_index + 1];

    /*
       if(p_offset == 648) {
       printf("CPU: %d - %d - %d + %d = %d\nweight0 = %d, sum = %d\n", *(scaled_rectangles_array[r_index+4] + p_offset),
     *(scaled_rectangles_array[r_index+5] + p_offset),
     *(scaled_rectangles_array[r_index+6] + p_offset),
     *(scaled_rectangles_array[r_index+7] + p_offset), sum, weights_array[w_index+1], sum);
     }*/

    if ((scaled_rectangles_array[r_index+8] != NULL)){
        sum += (*(scaled_rectangles_array[r_index+8] + p_offset)
                - *(scaled_rectangles_array[r_index + 9] + p_offset)
                - *(scaled_rectangles_array[r_index + 10] + p_offset)
                + *(scaled_rectangles_array[r_index + 11] + p_offset))
            * weights_array[w_index + 2];
    }
    if(sum >= t)
        return alpha2_array[tree_index];
    else
        return alpha1_array[tree_index];
}



int runCascadeClassifier( myCascade* _cascade, MyPoint pt, int start_stage )
{

    int p_offset, pq_offset;
    int i, j;
    unsigned int mean;
    unsigned int variance_norm_factor;
    int haar_counter = 0;
    int w_index = 0;
    int r_index = 0;
    int stage_sum;
    myCascade* cascade;
    cascade = _cascade;

    p_offset = pt.y * (cascade->sum.width) + pt.x;    //shifted widnow
    pq_offset = pt.y * (cascade->sqsum.width) + pt.x;

    /**************************************************************************
     * Image normalization
     * mean is the mean of the pixels in the detection window
     * cascade->pqi[pq_offset] are the squared pixel values (using the squared integral image)
     * inv_window_area is 1 over the total number of pixels in the detection window
     *************************************************************************/

    variance_norm_factor =  (cascade->pq0[pq_offset] - cascade->pq1[pq_offset] - cascade->pq2[pq_offset] + cascade->pq3[pq_offset]);
    mean = (cascade->p0[p_offset] - cascade->p1[p_offset] - cascade->p2[p_offset] + cascade->p3[p_offset]);

    //printf("CPU Row %d: Col %d: var: %d - %d - %d + %d = %d\nCol %d: mean: %d - %d - %d + %d = %d\n", pt.y, pt.x, cascade->pq0[pq_offset], cascade->pq1[pq_offset], cascade->pq2[pq_offset], cascade->pq3[pq_offset], variance_norm_factor, pt.x, cascade->p0[p_offset], cascade->p1[p_offset], cascade->p2[p_offset], cascade->p3[p_offset], mean);

    variance_norm_factor = (variance_norm_factor * cascade->inv_window_area);
    variance_norm_factor =  variance_norm_factor - mean*mean;

    /***********************************************
     * Note:
     * The int_sqrt is softwar integer squre root.
     * GPU has hardware for floating squre root (sqrtf).
     * In GPU, it is wise to convert the variance norm
     * into floating point, and use HW sqrtf function.
     * More info:
     * http://docs.nvidia.com/cuda/cuda-c-programming-guide/index.html#standard-functions
     **********************************************/
    if( variance_norm_factor > 0 )
        variance_norm_factor = int_sqrt(variance_norm_factor);
    else
        variance_norm_factor = 1;

    //printf("CPU: Row: %d, Col: %d, ID: %d: Variance = %d\n", pt.y, pt.x, p_offset, variance_norm_factor);
    /**************************************************
     * The major computation happens here.
     * For each scale in the image pyramid,
     * and for each shifted step of the filter,
     * send the shifted window through cascade filter.
     *
     * Note:
     *
     * Stages in the cascade filter are independent.
     * However, a face can be rejected by any stage.
     * Running stages in parallel delays the rejection,
     * which induces unnecessary computation.
     *
     * Filters in the same stage are also independent,
     * except that filter results need to be merged,
     * and compared with a per-stage threshold.
     *************************************************/
    for( i = start_stage; i < 25; i++) //cascade->n_stages; i++ ) Change here- Sharmila
    {

        /****************************************************
         * A shared variable that induces false dependency
         * 
         * To avoid it from limiting parallelism,
         * we can duplicate it multiple times,
         * e.g., using stage_sum_array[number_of_threads].
         * Then threads only need to sync at the end
         ***************************************************/
        stage_sum = 0;

        for( j = 0; j < stages_array[i]; j++ )
        {
            /*
               if(p_offset == 648) {
               printf("CPU p_offset = %d Stage = %d, Haar =%d\n", p_offset, i, j);
               }*/
            /**************************************************
             * Send the shifted window to a haar filter.
             **************************************************/
            stage_sum += evalWeakClassifier(variance_norm_factor, p_offset, haar_counter, w_index, r_index);
            n_features++;
            haar_counter++;
            w_index+=3;
            r_index+=12;
        } /* end of j loop */

        /**************************************************************
         * threshold of the stage. 
         * If the sum is below the threshold, 
         * no faces are detected, 
         * and the search is abandoned at the i-th stage (-i).
         * Otherwise, a face is detected (1)
         **************************************************************/

        /* the number "0.4" is empirically chosen for 5kk73 */
        if( stage_sum <  0.4 * stages_thresh_array[i] ){
            return -i;
        } /* end of the per-stage thresholding */
    } /* end of i loop */

    //printf("True: Vec ID = %d, Stage = %d, CPU: Row = %d, Col = %d: stage_sum = %ld < %d\n", pt.y*(cascade->sum.width-cascade->orig_window_size.width)+pt.x, i, pt.y, pt.x, stage_sum, (int)(0.4*stages_thresh_array[i]));
    return 1;
}


void ScaleImage_Invoker( myCascade* _cascade, float _factor, int sum_row, int sum_col, std::vector<MyRect>& _vec)
{

    myCascade* cascade = _cascade;

    float factor = _factor;
    MyPoint p;
    int result;
    int y1, y2, x2, x, y, step;
    std::vector<MyRect> *vec = &_vec;

    MySize winSize0 = cascade->orig_window_size;
    MySize winSize;

    winSize.width =  myRound(winSize0.width*factor);
    winSize.height =  myRound(winSize0.height*factor);
    y1 = 0;

    /********************************************
     * When filter window shifts to image boarder,
     * some margin need to be kept
     *********************************************/
    y2 = sum_row - winSize0.height;
    x2 = sum_col - winSize0.width;

    /********************************************
     * Step size of filter window shifting
     * Reducing step makes program faster,
     * but decreases quality of detection.
     * example:
     * step = factor > 2 ? 1 : 2;
     * 
     * For 5kk73, 
     * the factor and step can be kept constant,
     * unless you want to change input image.
     *
     * The step size is set to 1 for 5kk73,
     * i.e., shift the filter window by 1 pixel.
     *******************************************/	
    step = 1;

    /**********************************************
     * Shift the filter window over the image.
     * Each shift step is independent.
     * Shared data structure may limit parallelism.
     *
     * Some random hints (may or may not work):
     * Split or duplicate data structure.
     * Merge functions/loops to increase locality
     * Tiling to increase computation-to-memory ratio
     *********************************************/
    int i;
    for(i=0; i<(x2*y2); i++) {
        bit_vector[i] = true;
    }
    for( x = 0; x <= x2; x += step )
        for( y = y1; y <= y2; y += step )
        {
            p.x = x;
            p.y = y;

            /*********************************************
             * Optimization Oppotunity:
             * The same cascade filter is used each time
             ********************************************/
            result = runCascadeClassifier( cascade, p, 0 );

            /*******************************************************
             * If a face is detected,
             * record the coordinates of the filter window
             * the "push_back" function is from std:vec, more info:
             * http://en.wikipedia.org/wiki/Sequence_container_(C++)
             *
             * Note that, if the filter runs on GPUs,
             * the push_back operation is not possible on GPUs.
             * The GPU may need to use a simpler data structure,
             * e.g., an array, to store the coordinates of face,
             * which can be later memcpy from GPU to CPU to do push_back
             *******************************************************/
            int index = y*x2+x;
            if( result > 0 )
            {
                //printf("Result is greater than zero\n");
                MyRect r = {myRound(x*factor), myRound(y*factor), winSize.width, winSize.height};
                vec->push_back(r);
                //printf("Pushed back the result into vector\n");
                //bit_vector[index] = true;
            }
            else
                bit_vector[index] = false;
        }
    //printf("Completed scale image invoker\n");
    //fflush(stdout);
}

/*****************************************************
 * Compute the integral image (and squared integral)
 * Integral image helps quickly sum up an area.
 * More info:
 * http://en.wikipedia.org/wiki/Summed_area_table
 ****************************************************/
void integralImages( MyImage *src, MyIntImage *sum, MyIntImage *sqsum )
{
    int x, y, s, sq, t, tq;
    unsigned char it;
    int height = src->height;
    int width = src->width;
    unsigned char *data = src->data;
    int * sumData = sum->data;
    int * sqsumData = sqsum->data;

    for( y = 0; y < height; y++)
    {
        s = 0;
        sq = 0;
        /* loop over the number of columns */
        for( x = 0; x < width; x ++)
        {
            it = data[y*width+x];
            /* sum of the current row (integer)*/
            s += it; 
            sq += it*it;

            t = s;
            tq = sq;
            if (y != 0)
            {
                t += sumData[(y-1)*width+x];
                tq += sqsumData[(y-1)*width+x];
            }
            sumData[y*width+x]=t;
            sqsumData[y*width+x]=tq;
        }
    }
}

/***********************************************************
 * This function downsample an image using nearest neighbor
 * It is used to build the image pyramid
 **********************************************************/
void nearestNeighbor (MyImage *src, MyImage *dst)
{

    int y;
    int j;
    int x;
    int i;
    unsigned char* t;
    unsigned char* p;
    int w1 = src->width;
    int h1 = src->height;
    int w2 = dst->width;
    int h2 = dst->height;

    int rat = 0;

    unsigned char* src_data = src->data;
    unsigned char* dst_data = dst->data;


    int x_ratio = (int)((w1<<16)/w2) +1;
    int y_ratio = (int)((h1<<16)/h2) +1;

    for (i=0;i<h2;i++)
    {
        t = dst_data + i*w2;       //Pointer to next row in dst image
        y = ((i*y_ratio)>>16);
        p = src_data + y*w1;
        rat = 0;

        for (j=0;j<w2;j++)
        {
            x = (rat>>16);
            *t++ = p[x];
            rat += x_ratio;
        }
    }
}

void readTextClassifierForGPU()//(myCascade * cascade)
{
    /*number of stages of the cascade classifier*/
    int stages;
    /*total number of weak classifiers (one node each)*/
    int total_nodes = 0;
    int i, j, k;
    char mystring [12];
    int w_index = 0;
    int tree_index = 0;
    FILE *finfo = fopen("info.txt", "r");

    /**************************************************
     * how many stages are in the cascaded filter? 
     * the first line of info.txt is the number of stages 
     * (in the 5kk73 example, there are 25 stages)
     **************************************************/
    if ( fgets (mystring , 12 , finfo) != NULL )
    {
        stages = atoi(mystring);
    }
    i = 0;

    hstages_array = (int *)malloc(sizeof(int)*stages);

    /**************************************************
     * how many filters in each stage? 
     * They are specified in info.txt,
     * starting from second line.
     * (in the 5kk73 example, from line 2 to line 26)
     *************************************************/
    while ( fgets (mystring , 12 , finfo) != NULL )
    {
        hstages_array[i] = atoi(mystring);
        total_nodes += hstages_array[i];
        i++;
    }
    fclose(finfo);

    printf("Total number of haar features = %d\n", total_nodes);

    /* TODO: use matrices where appropriate */
    /***********************************************
     * Allocate a lot of array structures
     * Note that, to increase parallelism,
     * some arrays need to be splitted or duplicated
     **********************************************/

    hindex_x = (uint16_t *)malloc(sizeof(uint16_t)*total_nodes*3);
    hindex_y = (uint16_t *)malloc(sizeof(uint16_t)*total_nodes*3);
    hwidth = (uint16_t *)malloc(sizeof(uint16_t)*total_nodes*3);
    hheight = (uint16_t *)malloc(sizeof(uint16_t)*total_nodes*3);
    hweights_array = (int16_t *)malloc(sizeof(int16_t)*total_nodes*3);
    halpha1_array = (int16_t*)malloc(sizeof(int16_t)*total_nodes);
    halpha2_array = (int16_t*)malloc(sizeof(int16_t)*total_nodes);
    htree_thresh_array = (int16_t*)malloc(sizeof(int16_t)*total_nodes);
    hstages_thresh_array = (int16_t*)malloc(sizeof(int16_t)*stages);
    FILE *fp = fopen("class.txt", "r");

    /******************************************
     * Read the filter parameters in class.txt
     *
     * Each stage of the cascaded filter has:
     * 18 parameter per filter x tilter per stage
     * + 1 threshold per stage
     *
     * For example, in 5kk73, 
     * the first stage has 9 filters,
     * the first stage is specified using
     * 18 * 9 + 1 = 163 parameters
     * They are line 1 to 163 of class.txt
     *
     * The 18 parameters for each filter are:
     * 1 to 4: coordinates of rectangle 1
     * 5: weight of rectangle 1
     * 6 to 9: coordinates of rectangle 2
     * 10: weight of rectangle 2
     * 11 to 14: coordinates of rectangle 3
     * 15: weight of rectangle 3
     * 16: threshold of the filter
     * 17: alpha 1 of the filter
     * 18: alpha 2 of the filter
     ******************************************/

    /* loop over n of stages */
    for (i = 0; i < stages; i++)
    {    /* loop over n of trees */
        for (j = 0; j < hstages_array[i]; j++)
        {	/* loop over n of rectangular features */
            for(k = 0; k < 3; k++)
            {	/* loop over the n of vertices */
                //for (l = 0; l <4; l++)
                //{
                if (fgets (mystring , 12 , fp) != NULL)
                    hindex_x[w_index] = atoi(mystring);
                else
                    break;
                if (fgets (mystring , 12 , fp) != NULL)
                    hindex_y[w_index] = atoi(mystring);
                else
                    break;
                if (fgets (mystring , 12 , fp) != NULL)
                    hwidth[w_index] = atoi(mystring);
                else
                    break;
                if (fgets (mystring , 12 , fp) != NULL)
                    hheight[w_index] = atoi(mystring);
                else
                    break;
                //r_index++;
                //} /* end of l loop */

                if (fgets (mystring , 12 , fp) != NULL)
                {
                    hweights_array[w_index] = atoi(mystring);
                    /* Shift value to avoid overflow in the haar evaluation */
                    /*TODO: make more general */
                    /*weights_array[w_index]>>=8; */
                }
                else
                    break;
                w_index++;
            } /* end of k loop */

            if (fgets (mystring , 12 , fp) != NULL)
                htree_thresh_array[tree_index]= atoi(mystring);
            else
                break;
            if (fgets (mystring , 12 , fp) != NULL)
                halpha1_array[tree_index]= atoi(mystring);
            else
                break;
            if (fgets (mystring , 12 , fp) != NULL)
                halpha2_array[tree_index]= atoi(mystring);
            else
                break;
            tree_index++;

            if (j == hstages_array[i]-1)
            {
                if (fgets (mystring , 12 , fp) != NULL)
                    hstages_thresh_array[i] = atoi(mystring);
                else
                    break;
            }
        } /* end of j loop */
    } /* end of i loop */
    fclose(fp);
}

void readTextClassifier()//(myCascade * cascade)
{
    /*number of stages of the cascade classifier*/
    int stages;
    /*total number of weak classifiers (one node each)*/
    int total_nodes = 0;
    int i, j, k, l;
    char mystring [12];
    int r_index = 0;
    int w_index = 0;
    int tree_index = 0;
    FILE *finfo = fopen("info.txt", "r");

    /**************************************************
    /* how many stages are in the cascaded filter? 
    /* the first line of info.txt is the number of stages 
    /* (in the 5kk73 example, there are 25 stages)
     **************************************************/
    if ( fgets (mystring , 12 , finfo) != NULL )
    {
        stages = atoi(mystring);
    }
    i = 0;

    stages_array = (int *)malloc(sizeof(int)*stages);

    /**************************************************
     * how many filters in each stage? 
     * They are specified in info.txt,
     * starting from second line.
     * (in the 5kk73 example, from line 2 to line 26)
     *************************************************/
    while ( fgets (mystring , 12 , finfo) != NULL )
    {
        stages_array[i] = atoi(mystring);
        total_nodes += stages_array[i];
        i++;
    }
    fclose(finfo);


    /* TODO: use matrices where appropriate */
    /***********************************************
     * Allocate a lot of array structures
     * Note that, to increase parallelism,
     * some arrays need to be splitted or duplicated
     **********************************************/
    rectangles_array = (int *)malloc(sizeof(int)*total_nodes*12);
    scaled_rectangles_array = (int **)malloc(sizeof(int*)*total_nodes*12);
    weights_array = (int *)malloc(sizeof(int)*total_nodes*3);
    alpha1_array = (int*)malloc(sizeof(int)*total_nodes);
    alpha2_array = (int*)malloc(sizeof(int)*total_nodes);
    tree_thresh_array = (int*)malloc(sizeof(int)*total_nodes);
    stages_thresh_array = (int*)malloc(sizeof(int)*stages);
    FILE *fp = fopen("class.txt", "r");

    /******************************************
     * Read the filter parameters in class.txt
     *
     * Each stage of the cascaded filter has:
     * 18 parameter per filter x tilter per stage
     * + 1 threshold per stage
     *
     * For example, in 5kk73, 
     * the first stage has 9 filters,
     * the first stage is specified using
     * 18 * 9 + 1 = 163 parameters
     * They are line 1 to 163 of class.txt
     *
     * The 18 parameters for each filter are:
     * 1 to 4: coordinates of rectangle 1
     * 5: weight of rectangle 1
     * 6 to 9: coordinates of rectangle 2
     * 10: weight of rectangle 2
     * 11 to 14: coordinates of rectangle 3
     * 15: weight of rectangle 3
     * 16: threshold of the filter
     * 17: alpha 1 of the filter
     * 18: alpha 2 of the filter
     ******************************************/

    /* loop over n of stages */
    for (i = 0; i < stages; i++)
    {    /* loop over n of trees */
        for (j = 0; j < stages_array[i]; j++)
        {	/* loop over n of rectangular features */
            for(k = 0; k < 3; k++)
            {	/* loop over the n of vertices */
                for (l = 0; l <4; l++)
                {
                    if (fgets (mystring , 12 , fp) != NULL)
                        rectangles_array[r_index] = atoi(mystring);
                    else
                        break;
                    r_index++;
                } /* end of l loop */

                if (fgets (mystring , 12 , fp) != NULL)
                {
                    weights_array[w_index] = atoi(mystring);
                    /* Shift value to avoid overflow in the haar evaluation */
                    /*TODO: make more general */
                    /*weights_array[w_index]>>=8; */
                }
                else
                    break;
                w_index++;
            } /* end of k loop */

            if (fgets (mystring , 12 , fp) != NULL)
                tree_thresh_array[tree_index]= atoi(mystring);
            else
                break;
            if (fgets (mystring , 12 , fp) != NULL)
                alpha1_array[tree_index]= atoi(mystring);
            else
                break;
            if (fgets (mystring , 12 , fp) != NULL)
                alpha2_array[tree_index]= atoi(mystring);
            else
                break;
            tree_index++;

            if (j == stages_array[i]-1)
            {
                if (fgets (mystring , 12 , fp) != NULL)
                    stages_thresh_array[i] = atoi(mystring);
                else
                    break;
            }
        } /* end of j loop */
    } /* end of i loop */
    fclose(fp);
}


void releaseTextClassifier()
{
    free(stages_array);
    free(rectangles_array);
    free(scaled_rectangles_array);
    free(weights_array);
    free(tree_thresh_array);
    free(alpha1_array);
    free(alpha2_array);
    free(stages_thresh_array);
}

void releaseTextClassifierGPU()
{
    free(hstages_array);
    free(hindex_x);
    free(hindex_y);
    free(hweights_array);
    free(htree_thresh_array);
    free(halpha1_array);
    free(halpha2_array);
    free(hstages_thresh_array);
    free(bit_vector);
}

/* End of file. */
