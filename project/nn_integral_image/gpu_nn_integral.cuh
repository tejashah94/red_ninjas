#include "haar.h"
#include "image.h"
#include <stdio.h>
#include "stdio-wrapper.h"
#include "cuda_util.h"

#include "gpu_nn_integral_kernel.cuh"
#include "gpu_transpose_kernel.cuh"

//Setting up the kernel for device -- 32bit version
void nn_integralImageOnDevice(MyImage *src, MyIntImage *sum, MyIntImage *sqsum )
{
     /**************************************/
     //Timing related
     cudaError_t error;
     cudaEvent_t gpu_inc_start;
     cudaEvent_t gpu_inc_stop;
     cudaEvent_t gpu_exc_start;
     cudaEvent_t gpu_exc_stop;
     float inc_msecTotal;
     float exc_msecTotal;
   
     float mt2plusrs_excmsecTotal;
     float gpu_excmsecTotal;
    
     //CUDA Events 
     error = cudaEventCreate(&gpu_inc_start);
     if (error != cudaSuccess)
     {
         fprintf(stderr, "Failed to create start event (error code %s)!\n", cudaGetErrorString(error));
         exit(EXIT_FAILURE);
     }
     
     error = cudaEventCreate(&gpu_inc_stop);
     if (error != cudaSuccess)
     {
         fprintf(stderr, "Failed to create stop event (error code %s)!\n", cudaGetErrorString(error));
         exit(EXIT_FAILURE);
     
     }

     error = cudaEventCreate(&gpu_exc_start);
     if (error != cudaSuccess)
     {
         fprintf(stderr, "Failed to create start event (error code %s)!\n", cudaGetErrorString(error));
         exit(EXIT_FAILURE);
     }
     
     error = cudaEventCreate(&gpu_exc_stop);
     if (error != cudaSuccess)
     {
         fprintf(stderr, "Failed to create stop event (error code %s)!\n", cudaGetErrorString(error));
         exit(EXIT_FAILURE);
     
     }

     /**************************************/
     
     //Image Characteristics
     int src_w = src->width;
     int src_h = src->height;
     int dst_w = sum->width;
     int dst_h = sum->height;
     
     //Device Source Image
     MyImage device_srcimg;
     device_srcimg.height = src->height;
     device_srcimg.width =  src->width;
     int srcSize = device_srcimg.height * device_srcimg.width;
 
     //Downsample device image 
     MyImage device_nnimg;
     device_nnimg.height = sum->height;
     device_nnimg.width =  sum->width;
     int dstSize = device_nnimg.height * device_nnimg.width;

     int check = 0;

     printf("\n\tNN and II on GPU Started\n");
     
      //////////////////////////////////
     // ALLOCATION FOR LOCAL IMAGES   //
     //////////////////////////////////

     //Allocate device src
     check = CUDA_CHECK_RETURN(cudaMalloc((void**)&(device_srcimg.data), sizeof(unsigned char) * srcSize), __FILE__, __LINE__);
     if( check != 0){
           std::cerr << "Error: CudaMalloc not successfull for device source image" << std::endl;
           exit(1);
     }

       //allocate device dst
     check = CUDA_CHECK_RETURN(cudaMalloc((void**)&(device_nnimg.data), sizeof(unsigned char) * dstSize), __FILE__, __LINE__);
     if( check != 0){
           std::cerr << "Error: CudaMalloc not successfull for device dest image" << std::endl;
           exit(1);
     }

     //allocate space for sum and sqsum pixels only on device//
     MyIntImage d_sum, d_sqsum;
     d_sum.width = sum->width; d_sum.height = sum->height; 
     d_sqsum.width = sqsum->width; d_sqsum.height = sqsum->height;
  
      /////////////////////////////////////////////
     // ALLOCATION FOR LOCAL SUM/SQSUM IMAGES   //
     ////////////////////////////////////////////
     
     //Malloc for sum and sqsum 
     check = CUDA_CHECK_RETURN(cudaMalloc((void**)&(d_sum.data), sizeof(int)*dstSize), __FILE__, __LINE__);
     if( check != 0){
           std::cerr << "Error: CudaMalloc not successfull for device dest sum image" << std::endl;
           exit(1);
     }

     check = CUDA_CHECK_RETURN(cudaMalloc((void**)&(d_sqsum.data), sizeof(int*)*dstSize), __FILE__, __LINE__);
     if( check != 0){
           std::cerr << "Error: CudaMalloc not successfull for device dest sqsum image" << std::endl;
           exit(1);
     }  

     if(PRINT_LOG){
        printf("\tSrc size: %d x %d\n", src->width, src->height);
        printf("\tDst size: %d x %d\n", sum->width, sum->height);
     }
      
     //Get the scaling ratio of src and dest image
     int x_ratio = (int)((src_w<<16)/dst_w) +1;
     int y_ratio = (int)((src_h<<16)/dst_h) +1;
 
     // Execution Configuration for Orig ROW SCAN //
     int threadsPerBlock_rs = getSmallestPower2(dst_w);
     int threadsPerBlock_cs = getSmallestPower2(dst_h);
     
     int blocksPerGrid_rs = dst_h;
     int blocksPerGrid_cs = dst_w;
     
     if (threadsPerBlock_rs > 1024 || threadsPerBlock_cs > 1024)
     {
       printf("\tII: Supported only for Downsample Image width & height < 1024\n");
       printf("\tII: Currently passed Downsampled Image[w]: %d Image[h]: %d\n", dst_w, dst_h);
       cudaFree(device_srcimg.data);
       cudaFree(device_nnimg.data);
       cudaFree(d_sum.data);
       cudaFree(d_sqsum.data);
     }

     if(PRINT_GPU){
        std::cerr << "\t/***************GPU-LOG****************/" << std::endl;                              
        std::cerr << "\tThreads Per Block for RowScan: " << threadsPerBlock_rs << std::endl;
        std::cerr << "\tTBS per Grid for RowScan: " << blocksPerGrid_rs << std::endl;         
        std::cerr << "\tThreads Per Block for ColumnScan: " << threadsPerBlock_cs << std::endl;
        std::cerr << "\tTBS per Grid for ColumnScan: " << blocksPerGrid_cs << std::endl;         
        std::cerr << "\t/**************************************/" << std::endl;                              
     }                                                                                                       

      /*****************************************************************
     *rowscan does row-wise inclusive prefix scan for sum and sqsum
     *colscan does column-wise inclusive prefix scan for sum and sqsum*/

      //////////////////////////
     // ORIG ROW SCAN KERNEL //
     /////////////////////////

     //--Timing Start
     error = cudaEventRecord(gpu_inc_start, NULL);
     if (error != cudaSuccess)
     {
         fprintf(stderr, "Failed to record start event (error code %s)!\n", cudaGetErrorString(error));
         exit(EXIT_FAILURE);
     }
     
     //Copy source contents to a src on device
     check = CUDA_CHECK_RETURN(cudaMemcpy(device_srcimg.data, src->data, sizeof(unsigned char)*srcSize, cudaMemcpyHostToDevice), __FILE__, __LINE__);
     if( check != 0){
           std::cerr << "Error: CudaMemCpy not successfull for device source image" << std::endl;
           exit(1);
     }

     error = cudaEventRecord(gpu_exc_start, NULL);
     if (error != cudaSuccess)
     {
         fprintf(stderr, "Failed to record start event (error code %s)!\n", cudaGetErrorString(error));
         exit(EXIT_FAILURE);
     }

     //*******************************************//
     //Neareast Neighbor and Row Scan Kernel Call //
     //*******************************************//
     rowscan_nn_kernel<<<blocksPerGrid_rs, (threadsPerBlock_rs / 2)>>>(
                                                                        device_srcimg.data,
                                                                        d_sum.data, d_sqsum.data, 
                                                                        src_w, src_h, dst_w, dst_h,
                                                                        x_ratio, y_ratio, 
                                                                        threadsPerBlock_rs
                                                                       );
     
     check = CUDA_CHECK_RETURN( cudaPeekAtLastError(), __FILE__, __LINE__ );
     if( check != 0){
           std::cerr << "Error: CudaPeek on Row Scan not successfull for device dest image" << std::endl;
           exit(1);
     }
     
     check = CUDA_CHECK_RETURN( cudaDeviceSynchronize(), __FILE__, __LINE__ );
     if( check != 0){
           std::cerr << "Error: CudaSynchronize not successfull for device dest image" << std::endl;
           exit(1);
     }    

     // Record the stop event
     error = cudaEventRecord(gpu_exc_stop, NULL);
     if (error != cudaSuccess)
     {
         fprintf(stderr, "Failed to record stop event (error code %s)!\n", cudaGetErrorString(error));
         exit(EXIT_FAILURE);
     }

     // Wait for the stop event to complete
     error = cudaEventSynchronize(gpu_exc_stop);
     if (error != cudaSuccess)
     {
         fprintf(stderr, "Failed to synchronize on the stop event (error code %s)!\n", cudaGetErrorString(error));
         exit(EXIT_FAILURE);
     }

     error = cudaEventElapsedTime(&exc_msecTotal, gpu_exc_start, gpu_exc_stop);
     if (error != cudaSuccess)
     {
         fprintf(stderr, "Failed to get time elapsed between events (error code %s)!\n", cudaGetErrorString(error));
         exit(EXIT_FAILURE);
     }

     printf("\tNN: Rowscan Done on GPU-->: Exclusive Time: %f ms\n", exc_msecTotal);
     gpu_excmsecTotal = exc_msecTotal;


      /////////////////////////////////
     //  MATRIX TRANSPOSE 1 KERNEL  //
     ////////////////////////////////

     //allocate space for transpose sum and sqsum pixels only on device//
     MyIntImage transpose_dsum, transpose_dsqsum;
     transpose_dsum.width = sum->width; transpose_dsum.height = sum->height; 
     transpose_dsqsum.width = sqsum->width; transpose_dsqsum.height = sqsum->height;

     //Malloc for transpose sum and sqsum 
     check = CUDA_CHECK_RETURN(cudaMalloc((void**)&(transpose_dsum.data), sizeof(int)*dstSize), __FILE__, __LINE__);
     if( check != 0){
          std::cerr << "Error: CudaMalloc not successfull for device transpose sum image" << std::endl;
          exit(1);
     }

     check = CUDA_CHECK_RETURN(cudaMalloc((void**)&(transpose_dsqsum.data), sizeof(int)*dstSize), __FILE__, __LINE__);
     if( check != 0){
          std::cerr << "Error: CudaMalloc not successfull for device tranpsoe sqsum image" << std::endl;
          exit(1);
     } 


     // Execution Configuration for  Matrix Transpose 1//
     int tx = BLOCK_SIZE;
     int ty = BLOCK_SIZE;
     int bx = (dst_w + BLOCK_SIZE - 1)/BLOCK_SIZE;
     int by = (dst_h + BLOCK_SIZE - 1)/BLOCK_SIZE;
     
     dim3 blocks(tx,ty);
     dim3 grid(bx,by);

     error = cudaEventRecord(gpu_exc_start, NULL);
     if (error != cudaSuccess)
     {
          fprintf(stderr, "Failed to record start event (error code %s)!\n", cudaGetErrorString(error));
          exit(EXIT_FAILURE);
     }
 
     //**********************************//
     // matrix transpose 1  Kernel Call //
     //********************************//
     transpose_kernel<<<grid,blocks>>>(d_sum.data,transpose_dsum.data,  
                                       d_sqsum.data, 
                                       transpose_dsqsum.data, 
                                       dst_w, dst_h);
     
     check = CUDA_CHECK_RETURN( cudaPeekAtLastError(), __FILE__, __LINE__ );
     if( check != 0){
          std::cerr << "Error: CudaPeek on Row Scan not successfull for device dest image" << std::endl;
          exit(1);
     }

     check = CUDA_CHECK_RETURN( cudaDeviceSynchronize(), __FILE__, __LINE__ );
     if( check != 0){
          std::cerr << "Error: CudaSynchronize not successfull for device dest image" << std::endl;
          exit(1);
     }    

     // Record the stop event
     error = cudaEventRecord(gpu_exc_stop, NULL);
     if (error != cudaSuccess)
     {
          fprintf(stderr, "Failed to record stop event (error code %s)!\n", cudaGetErrorString(error));
          exit(EXIT_FAILURE);
     }

     // Wait for the stop event to complete
     error = cudaEventSynchronize(gpu_exc_stop);
     if (error != cudaSuccess)
     {
        fprintf(stderr, "Failed to synchronize on the stop event (error code %s)!\n", cudaGetErrorString(error));
          exit(EXIT_FAILURE);
     }

     error = cudaEventElapsedTime(&exc_msecTotal, gpu_exc_start, gpu_exc_stop);
     if (error != cudaSuccess)
     {
        fprintf(stderr, "Failed to get time elapsed between events (error code %s)!\n", cudaGetErrorString(error));
          exit(EXIT_FAILURE);
     }

     printf("\tII: Matrix Transpose1 Done on GPU--> Exclusive Time: %f ms\n", exc_msecTotal);
     gpu_excmsecTotal += exc_msecTotal;
     mt2plusrs_excmsecTotal = exc_msecTotal;

      
     /////////////////////////////////////
     // ROW SCAN ONLY (w/o NN) KERNEL  //
     ////////////////////////////////////

     error = cudaEventRecord(gpu_exc_start, NULL);
     if (error != cudaSuccess)
     {
          fprintf(stderr, "Failed to record start event (error code %s)!\n", cudaGetErrorString(error));
          exit(EXIT_FAILURE);
     }

      //***************************//
     // row scan only Kernel Call //
     //**************************//
     rowscan_only_kernel<<<blocksPerGrid_cs, (threadsPerBlock_cs / 2)>>>(transpose_dsum.data, 
                                                                  transpose_dsqsum.data, 
                                                                  dst_h, threadsPerBlock_cs);
     
     check = CUDA_CHECK_RETURN( cudaPeekAtLastError(), __FILE__, __LINE__ );
     if( check != 0){
          std::cerr << "Error: CudaPeek on Row Scan not successfull for device dest image" << std::endl;
          exit(1);
     }

     check = CUDA_CHECK_RETURN( cudaDeviceSynchronize(), __FILE__, __LINE__ );
     if( check != 0){
          std::cerr << "Error: CudaSynchronize not successfull for device dest image" << std::endl;
          exit(1);
     }    

     // Record the stop event
     error = cudaEventRecord(gpu_exc_stop, NULL);
     if (error != cudaSuccess)
     {
          fprintf(stderr, "Failed to record stop event (error code %s)!\n", cudaGetErrorString(error));
          exit(EXIT_FAILURE);
     }

     // Wait for the stop event to complete
     error = cudaEventSynchronize(gpu_exc_stop);
     if (error != cudaSuccess)
     {
          fprintf(stderr, "Failed to synchronize on the stop event (error code %s)!\n", cudaGetErrorString(error));
          exit(EXIT_FAILURE);
     }

     error = cudaEventElapsedTime(&exc_msecTotal, gpu_exc_start, gpu_exc_stop);
     if (error != cudaSuccess)
     {
          fprintf(stderr, "Failed to get time elapsed between events (error code %s)!\n", cudaGetErrorString(error));
          exit(EXIT_FAILURE);
     }

     printf("\tII: RowScan Only on GPU Done--> Exclusive Time: %f ms\n", exc_msecTotal);
     gpu_excmsecTotal += exc_msecTotal;
     mt2plusrs_excmsecTotal += exc_msecTotal;
     
      /////////////////////////////////
     //  MATRIX TRANSPOSE 2 KERNEL  //
     ////////////////////////////////
   
     // Execution Configuration for  Matrix Transpose 2//
     bx = (dst_h + BLOCK_SIZE - 1)/BLOCK_SIZE;
     by = (dst_w + BLOCK_SIZE)/BLOCK_SIZE;
     dim3 blocks2(tx,ty);
     dim3 grid2(bx,by);
     
     error = cudaEventRecord(gpu_exc_start, NULL);
     if (error != cudaSuccess)
     {
          fprintf(stderr, "Failed to record start event (error code %s)!\n", cudaGetErrorString(error));
          exit(EXIT_FAILURE);
     }

     //**********************************//
     // matrix transpose 2  Kernel Call //
     //********************************//
     transpose_kernel<<<grid2, blocks2>>>(transpose_dsum.data, 
                                          d_sum.data, transpose_dsqsum.data, 
                                          d_sqsum.data, dst_h, dst_w);

     check = CUDA_CHECK_RETURN( cudaPeekAtLastError(), __FILE__, __LINE__ );
     if( check != 0){
          std::cerr << "Error: CudaPeek on Row Scan not successfull for device dest image" << std::endl;
          exit(1);
     }

     check = CUDA_CHECK_RETURN( cudaDeviceSynchronize(), __FILE__, __LINE__ );
     if( check != 0){
          std::cerr << "Error: CudaSynchronize not successfull for device dest image" << std::endl;
          exit(1);
     }    

     // Record the stop event
     error = cudaEventRecord(gpu_exc_stop, NULL);
     if (error != cudaSuccess)
     {
          fprintf(stderr, "Failed to record stop event (error code %s)!\n", cudaGetErrorString(error));
          exit(EXIT_FAILURE);
     }

     // Wait for the stop event to complete
     error = cudaEventSynchronize(gpu_exc_stop);
     if (error != cudaSuccess)
     {
          fprintf(stderr, "Failed to synchronize on the stop event (error code %s)!\n", cudaGetErrorString(error));
          exit(EXIT_FAILURE);
     }

     error = cudaEventElapsedTime(&exc_msecTotal, gpu_exc_start, gpu_exc_stop);
     if (error != cudaSuccess)
     {
          fprintf(stderr, "Failed to get time elapsed between events (error code %s)!\n", cudaGetErrorString(error));
          exit(EXIT_FAILURE);
     }

     printf("\tII:Matrix Transpose2 Done on GPU- Exclusive Time: %f ms\n", exc_msecTotal);
     gpu_excmsecTotal += exc_msecTotal;
     mt2plusrs_excmsecTotal += exc_msecTotal;
     
      
     /////////////////////////////////
     // CUDA MEMCpy of all results///
     ////////////////////////////////


     //Copy back the sum from device
     check = CUDA_CHECK_RETURN(cudaMemcpy(sum->data, d_sum.data, sizeof(int)*dstSize, cudaMemcpyDeviceToHost), __FILE__, __LINE__);
     if( check != 0){
          std::cerr << "Error: CudaMemCpy not successfull for device dest sum image" << std::endl;
          exit(1);
     }

     //Copy back the sq_sum from device
     check = CUDA_CHECK_RETURN(cudaMemcpy(sqsum->data, d_sqsum.data, sizeof(int)*dstSize, cudaMemcpyDeviceToHost), __FILE__, __LINE__);
     if( check != 0){
          std::cerr << "Error: CudaMemcpy not successfull for device dest sqsum image" << std::endl;
          exit(1);
     }

     // Record the stop event
     error = cudaEventRecord(gpu_inc_stop, NULL);
     if (error != cudaSuccess)
     {
          fprintf(stderr, "Failed to record stop event (error code %s)!\n", cudaGetErrorString(error));
          exit(EXIT_FAILURE);
     }

     // Wait for the stop event to complete
     error = cudaEventSynchronize(gpu_inc_stop);
     if (error != cudaSuccess)
     {
          fprintf(stderr, "Failed to synchronize on the stop event (error code %s)!\n", cudaGetErrorString(error));
          exit(EXIT_FAILURE);
     }

     error = cudaEventElapsedTime(&inc_msecTotal, gpu_inc_start, gpu_inc_stop);
     if (error != cudaSuccess)
     {
          fprintf(stderr, "Failed to get time elapsed between events (error code %s)!\n", cudaGetErrorString(error));
          exit(EXIT_FAILURE);
     }

     printf("\t2 Matrix Transposes  + RowScan Only Exclusive Time: %f ms\n", mt2plusrs_excmsecTotal);
     printf("\tNN and II on GPU complete--> Combined Exclusive Time: %f ms, Total Inclusive time: %f ms\n", gpu_excmsecTotal, inc_msecTotal);

     //Destroy Events
     cudaEventDestroy(gpu_exc_start);
     cudaEventDestroy(gpu_exc_stop);
     cudaEventDestroy(gpu_inc_start);
     cudaEventDestroy(gpu_inc_stop);

     //Free resources
     cudaFree(device_srcimg.data);
     cudaFree(device_nnimg.data);
     cudaFree(d_sum.data);
     cudaFree(d_sqsum.data);
     cudaFree(transpose_dsum.data);
     cudaFree(transpose_dsqsum.data);
}


//Setting up the kernel for device -- 16bit version
void nn_integralImageOnDevice16_t(MyImage *src, MyIntImage16_t *sum, MyIntImage16_t *sqsum )
{
     /**************************************/
     //Timing related
     cudaError_t error;
     cudaEvent_t gpu_inc_start;
     cudaEvent_t gpu_inc_stop;
     cudaEvent_t gpu_exc_start;
     cudaEvent_t gpu_exc_stop;
     float inc_msecTotal;
     float exc_msecTotal;
   
     float mt2plusrs_excmsecTotal;
     float gpu_excmsecTotal;
    
     //CUDA Events 
     error = cudaEventCreate(&gpu_inc_start);
     if (error != cudaSuccess)
     {
         fprintf(stderr, "Failed to create start event (error code %s)!\n", cudaGetErrorString(error));
         exit(EXIT_FAILURE);
     }
     
     error = cudaEventCreate(&gpu_inc_stop);
     if (error != cudaSuccess)
     {
         fprintf(stderr, "Failed to create stop event (error code %s)!\n", cudaGetErrorString(error));
         exit(EXIT_FAILURE);
     
     }

     error = cudaEventCreate(&gpu_exc_start);
     if (error != cudaSuccess)
     {
         fprintf(stderr, "Failed to create start event (error code %s)!\n", cudaGetErrorString(error));
         exit(EXIT_FAILURE);
     }
     
     error = cudaEventCreate(&gpu_exc_stop);
     if (error != cudaSuccess)
     {
         fprintf(stderr, "Failed to create stop event (error code %s)!\n", cudaGetErrorString(error));
         exit(EXIT_FAILURE);
     
     }

     /**************************************/
     
     //Image Characteristics
     int src_w = src->width;
     int src_h = src->height;
     int dst_w = sum->width;
     int dst_h = sum->height;
     
     //Device Source Image
     MyImage device_srcimg;
     device_srcimg.height = src->height;
     device_srcimg.width =  src->width;
     int srcSize = device_srcimg.height * device_srcimg.width;
 
     //Downsample device image 
     MyImage device_nnimg;
     device_nnimg.height = sum->height;
     device_nnimg.width =  sum->width;
     int dstSize = device_nnimg.height * device_nnimg.width;

     int check = 0;

     printf("\n\tNN and II on GPU Started\n");
     
      //////////////////////////////////
     // ALLOCATION FOR LOCAL IMAGES   //
     //////////////////////////////////

     //Allocate device src
     check = CUDA_CHECK_RETURN(cudaMalloc((void**)&(device_srcimg.data), sizeof(unsigned char) * srcSize), __FILE__, __LINE__);
     if( check != 0){
           std::cerr << "Error: CudaMalloc not successfull for device source image" << std::endl;
           exit(1);
     }

       //allocate device dst
     check = CUDA_CHECK_RETURN(cudaMalloc((void**)&(device_nnimg.data), sizeof(unsigned char) * dstSize), __FILE__, __LINE__);
     if( check != 0){
           std::cerr << "Error: CudaMalloc not successfull for device dest image" << std::endl;
           exit(1);
     }

     //allocate space for sum and sqsum pixels only on device//
     MyIntImage16_t d_sum, d_sqsum;
     d_sum.width = sum->width; d_sum.height = sum->height; 
     d_sqsum.width = sqsum->width; d_sqsum.height = sqsum->height;
  
      /////////////////////////////////////////////
     // ALLOCATION FOR LOCAL SUM/SQSUM IMAGES   //
     ////////////////////////////////////////////
     
     //Malloc for sum and sqsum 
     check = CUDA_CHECK_RETURN(cudaMalloc((void**)&(d_sum.data), sizeof(int16_t)*dstSize), __FILE__, __LINE__);
     if( check != 0){
           std::cerr << "Error: CudaMalloc not successfull for device dest sum image" << std::endl;
           exit(1);
     }

     check = CUDA_CHECK_RETURN(cudaMalloc((void**)&(d_sqsum.data), sizeof(int16_t)*dstSize), __FILE__, __LINE__);
     if( check != 0){
           std::cerr << "Error: CudaMalloc not successfull for device dest sqsum image" << std::endl;
           exit(1);
     }  

     if(PRINT_LOG){
        printf("\tSrc size: %d x %d\n", src->width, src->height);
        printf("\tDst size: %d x %d\n", sum->width, sum->height);
     }
      
     //Get the scaling ratio of src and dest image
     int x_ratio = (int)((src_w<<16)/dst_w) +1;
     int y_ratio = (int)((src_h<<16)/dst_h) +1;
 
     // Execution Configuration for Orig ROW SCAN //
     int threadsPerBlock_rs = getSmallestPower2(dst_w);
     int threadsPerBlock_cs = getSmallestPower2(dst_h);
     
     int blocksPerGrid_rs = dst_h;
     int blocksPerGrid_cs = dst_w;
     
     if (threadsPerBlock_rs > 1024 || threadsPerBlock_cs > 1024)
     {
       printf("\tII: Supported only for Downsample Image width & height < 1024\n");
       printf("\tII: Currently passed Downsampled Image[w]: %d Image[h]: %d\n", dst_w, dst_h);
       cudaFree(device_srcimg.data);
       cudaFree(device_nnimg.data);
       cudaFree(d_sum.data);
       cudaFree(d_sqsum.data);
     }

     if(PRINT_GPU){
        std::cerr << "\t/***************GPU-LOG****************/" << std::endl;                              
        std::cerr << "\tThreads Per Block for RowScan: " << threadsPerBlock_rs << std::endl;
        std::cerr << "\tTBS per Grid for RowScan: " << blocksPerGrid_rs << std::endl;         
        std::cerr << "\tThreads Per Block for ColumnScan: " << threadsPerBlock_cs << std::endl;
        std::cerr << "\tTBS per Grid for ColumnScan: " << blocksPerGrid_cs << std::endl;         
        std::cerr << "\t/**************************************/" << std::endl;                              
     }                                                                                                       

      /*****************************************************************
     *rowscan does row-wise inclusive prefix scan for sum and sqsum
     *colscan does column-wise inclusive prefix scan for sum and sqsum*/

      //////////////////////////
     // ORIG ROW SCAN KERNEL //
     /////////////////////////

     //--Timing Start
     error = cudaEventRecord(gpu_inc_start, NULL);
     if (error != cudaSuccess)
     {
         fprintf(stderr, "Failed to record start event (error code %s)!\n", cudaGetErrorString(error));
         exit(EXIT_FAILURE);
     }
     
     //Copy source contents to a src on device
     check = CUDA_CHECK_RETURN(cudaMemcpy(device_srcimg.data, src->data, sizeof(unsigned char)*srcSize, cudaMemcpyHostToDevice), __FILE__, __LINE__);
     if( check != 0){
           std::cerr << "Error: CudaMemCpy not successfull for device source image" << std::endl;
           exit(1);
     }

     error = cudaEventRecord(gpu_exc_start, NULL);
     if (error != cudaSuccess)
     {
         fprintf(stderr, "Failed to record start event (error code %s)!\n", cudaGetErrorString(error));
         exit(EXIT_FAILURE);
     }

     //*******************************************//
     //Neareast Neighbor and Row Scan Kernel Call //
     //*******************************************//
     rowscan_nn_kernel16_t<<<blocksPerGrid_rs, (threadsPerBlock_rs / 2)>>>(
                                                                        device_srcimg.data,
                                                                        d_sum.data, d_sqsum.data, 
                                                                        src_w, src_h, dst_w, dst_h,
                                                                        x_ratio, y_ratio, 
                                                                        threadsPerBlock_rs
                                                                       );
     
     check = CUDA_CHECK_RETURN( cudaPeekAtLastError(), __FILE__, __LINE__ );
     if( check != 0){
           std::cerr << "Error: CudaPeek on Row Scan not successfull for device dest image" << std::endl;
           exit(1);
     }
     
     check = CUDA_CHECK_RETURN( cudaDeviceSynchronize(), __FILE__, __LINE__ );
     if( check != 0){
           std::cerr << "Error: CudaSynchronize not successfull for device dest image" << std::endl;
           exit(1);
     }    

     // Record the stop event
     error = cudaEventRecord(gpu_exc_stop, NULL);
     if (error != cudaSuccess)
     {
         fprintf(stderr, "Failed to record stop event (error code %s)!\n", cudaGetErrorString(error));
         exit(EXIT_FAILURE);
     }

     // Wait for the stop event to complete
     error = cudaEventSynchronize(gpu_exc_stop);
     if (error != cudaSuccess)
     {
         fprintf(stderr, "Failed to synchronize on the stop event (error code %s)!\n", cudaGetErrorString(error));
         exit(EXIT_FAILURE);
     }

     error = cudaEventElapsedTime(&exc_msecTotal, gpu_exc_start, gpu_exc_stop);
     if (error != cudaSuccess)
     {
         fprintf(stderr, "Failed to get time elapsed between events (error code %s)!\n", cudaGetErrorString(error));
         exit(EXIT_FAILURE);
     }

     printf("\tNN: Rowscan Done on GPU-->: Exclusive Time: %f ms\n", exc_msecTotal);
     gpu_excmsecTotal = exc_msecTotal;


      /////////////////////////////////
     //  MATRIX TRANSPOSE 1 KERNEL  //
     ////////////////////////////////

     //allocate space for transpose sum and sqsum pixels only on device//
     MyIntImage16_t transpose_dsum, transpose_dsqsum;
     transpose_dsum.width = sum->width; transpose_dsum.height = sum->height; 
     transpose_dsqsum.width = sqsum->width; transpose_dsqsum.height = sqsum->height;

     //Malloc for transpose sum and sqsum 
     check = CUDA_CHECK_RETURN(cudaMalloc((void**)&(transpose_dsum.data), sizeof(int16_t)*dstSize), __FILE__, __LINE__);
     if( check != 0){
          std::cerr << "Error: CudaMalloc not successfull for device transpose sum image" << std::endl;
          exit(1);
     }

     check = CUDA_CHECK_RETURN(cudaMalloc((void**)&(transpose_dsqsum.data), sizeof(int16_t)*dstSize), __FILE__, __LINE__);
     if( check != 0){
          std::cerr << "Error: CudaMalloc not successfull for device tranpsoe sqsum image" << std::endl;
          exit(1);
     } 


     // Execution Configuration for  Matrix Transpose 1//
     int tx = BLOCK_SIZE;
     int ty = BLOCK_SIZE;
     int bx = (dst_w + BLOCK_SIZE - 1)/BLOCK_SIZE;
     int by = (dst_h + BLOCK_SIZE - 1)/BLOCK_SIZE;
     
     dim3 blocks(tx,ty);
     dim3 grid(bx,by);

     error = cudaEventRecord(gpu_exc_start, NULL);
     if (error != cudaSuccess)
     {
          fprintf(stderr, "Failed to record start event (error code %s)!\n", cudaGetErrorString(error));
          exit(EXIT_FAILURE);
     }
 
     //**********************************//
     // matrix transpose 1  Kernel Call //
     //********************************//
     transpose_kernel16_t<<<grid,blocks>>>(d_sum.data,transpose_dsum.data,  
                                       d_sqsum.data, 
                                       transpose_dsqsum.data, 
                                       dst_w, dst_h);
     
     check = CUDA_CHECK_RETURN( cudaPeekAtLastError(), __FILE__, __LINE__ );
     if( check != 0){
          std::cerr << "Error: CudaPeek on Row Scan not successfull for device dest image" << std::endl;
          exit(1);
     }

     check = CUDA_CHECK_RETURN( cudaDeviceSynchronize(), __FILE__, __LINE__ );
     if( check != 0){
          std::cerr << "Error: CudaSynchronize not successfull for device dest image" << std::endl;
          exit(1);
     }    

     // Record the stop event
     error = cudaEventRecord(gpu_exc_stop, NULL);
     if (error != cudaSuccess)
     {
          fprintf(stderr, "Failed to record stop event (error code %s)!\n", cudaGetErrorString(error));
          exit(EXIT_FAILURE);
     }

     // Wait for the stop event to complete
     error = cudaEventSynchronize(gpu_exc_stop);
     if (error != cudaSuccess)
     {
        fprintf(stderr, "Failed to synchronize on the stop event (error code %s)!\n", cudaGetErrorString(error));
          exit(EXIT_FAILURE);
     }

     error = cudaEventElapsedTime(&exc_msecTotal, gpu_exc_start, gpu_exc_stop);
     if (error != cudaSuccess)
     {
        fprintf(stderr, "Failed to get time elapsed between events (error code %s)!\n", cudaGetErrorString(error));
          exit(EXIT_FAILURE);
     }

     printf("\tII: Matrix Transpose1 Done on GPU--> Exclusive Time: %f ms\n", exc_msecTotal);
     gpu_excmsecTotal += exc_msecTotal;
     mt2plusrs_excmsecTotal = exc_msecTotal;

      
     /////////////////////////////////////
     // ROW SCAN ONLY (w/o NN) KERNEL  //
     ////////////////////////////////////

     error = cudaEventRecord(gpu_exc_start, NULL);
     if (error != cudaSuccess)
     {
          fprintf(stderr, "Failed to record start event (error code %s)!\n", cudaGetErrorString(error));
          exit(EXIT_FAILURE);
     }

      //***************************//
     // row scan only Kernel Call //
     //**************************//
     rowscan_only_kernel16_t<<<blocksPerGrid_cs, (threadsPerBlock_cs / 2)>>>(transpose_dsum.data, 
                                                                  transpose_dsqsum.data, 
                                                                  dst_h, threadsPerBlock_cs);
     
     check = CUDA_CHECK_RETURN( cudaPeekAtLastError(), __FILE__, __LINE__ );
     if( check != 0){
          std::cerr << "Error: CudaPeek on Row Scan not successfull for device dest image" << std::endl;
          exit(1);
     }

     check = CUDA_CHECK_RETURN( cudaDeviceSynchronize(), __FILE__, __LINE__ );
     if( check != 0){
          std::cerr << "Error: CudaSynchronize not successfull for device dest image" << std::endl;
          exit(1);
     }    

     // Record the stop event
     error = cudaEventRecord(gpu_exc_stop, NULL);
     if (error != cudaSuccess)
     {
          fprintf(stderr, "Failed to record stop event (error code %s)!\n", cudaGetErrorString(error));
          exit(EXIT_FAILURE);
     }

     // Wait for the stop event to complete
     error = cudaEventSynchronize(gpu_exc_stop);
     if (error != cudaSuccess)
     {
          fprintf(stderr, "Failed to synchronize on the stop event (error code %s)!\n", cudaGetErrorString(error));
          exit(EXIT_FAILURE);
     }

     error = cudaEventElapsedTime(&exc_msecTotal, gpu_exc_start, gpu_exc_stop);
     if (error != cudaSuccess)
     {
          fprintf(stderr, "Failed to get time elapsed between events (error code %s)!\n", cudaGetErrorString(error));
          exit(EXIT_FAILURE);
     }

     printf("\tII: RowScan Only on GPU Done--> Exclusive Time: %f ms\n", exc_msecTotal);
     gpu_excmsecTotal += exc_msecTotal;
     mt2plusrs_excmsecTotal += exc_msecTotal;
     
      /////////////////////////////////
     //  MATRIX TRANSPOSE 2 KERNEL  //
     ////////////////////////////////
   
     // Execution Configuration for  Matrix Transpose 2//
     bx = (dst_h + BLOCK_SIZE - 1)/BLOCK_SIZE;
     by = (dst_w + BLOCK_SIZE)/BLOCK_SIZE;
     dim3 blocks2(tx,ty);
     dim3 grid2(bx,by);
     
     error = cudaEventRecord(gpu_exc_start, NULL);
     if (error != cudaSuccess)
     {
          fprintf(stderr, "Failed to record start event (error code %s)!\n", cudaGetErrorString(error));
          exit(EXIT_FAILURE);
     }

     //**********************************//
     // matrix transpose 2  Kernel Call //
     //********************************//
     transpose_kernel16_t<<<grid2, blocks2>>>(transpose_dsum.data, 
                                          d_sum.data, transpose_dsqsum.data, 
                                          d_sqsum.data, dst_h, dst_w);

     check = CUDA_CHECK_RETURN( cudaPeekAtLastError(), __FILE__, __LINE__ );
     if( check != 0){
          std::cerr << "Error: CudaPeek on Row Scan not successfull for device dest image" << std::endl;
          exit(1);
     }

     check = CUDA_CHECK_RETURN( cudaDeviceSynchronize(), __FILE__, __LINE__ );
     if( check != 0){
          std::cerr << "Error: CudaSynchronize not successfull for device dest image" << std::endl;
          exit(1);
     }    

     // Record the stop event
     error = cudaEventRecord(gpu_exc_stop, NULL);
     if (error != cudaSuccess)
     {
          fprintf(stderr, "Failed to record stop event (error code %s)!\n", cudaGetErrorString(error));
          exit(EXIT_FAILURE);
     }

     // Wait for the stop event to complete
     error = cudaEventSynchronize(gpu_exc_stop);
     if (error != cudaSuccess)
     {
          fprintf(stderr, "Failed to synchronize on the stop event (error code %s)!\n", cudaGetErrorString(error));
          exit(EXIT_FAILURE);
     }

     error = cudaEventElapsedTime(&exc_msecTotal, gpu_exc_start, gpu_exc_stop);
     if (error != cudaSuccess)
     {
          fprintf(stderr, "Failed to get time elapsed between events (error code %s)!\n", cudaGetErrorString(error));
          exit(EXIT_FAILURE);
     }

     printf("\tII:Matrix Transpose2 Done on GPU- Exclusive Time: %f ms\n", exc_msecTotal);
     gpu_excmsecTotal += exc_msecTotal;
     mt2plusrs_excmsecTotal += exc_msecTotal;
     
      
     /////////////////////////////////
     // CUDA MEMCpy of all results///
     ////////////////////////////////


     //Copy back the sum from device
     check = CUDA_CHECK_RETURN(cudaMemcpy(sum->data, d_sum.data, sizeof(int16_t)*dstSize, cudaMemcpyDeviceToHost), __FILE__, __LINE__);
     if( check != 0){
          std::cerr << "Error: CudaMemCpy not successfull for device dest sum image" << std::endl;
          exit(1);
     }

     //Copy back the sq_sum from device
     check = CUDA_CHECK_RETURN(cudaMemcpy(sqsum->data, d_sqsum.data, sizeof(int16_t)*dstSize, cudaMemcpyDeviceToHost), __FILE__, __LINE__);
     if( check != 0){
          std::cerr << "Error: CudaMemcpy not successfull for device dest sqsum image" << std::endl;
          exit(1);
     }

     // Record the stop event
     error = cudaEventRecord(gpu_inc_stop, NULL);
     if (error != cudaSuccess)
     {
          fprintf(stderr, "Failed to record stop event (error code %s)!\n", cudaGetErrorString(error));
          exit(EXIT_FAILURE);
     }

     // Wait for the stop event to complete
     error = cudaEventSynchronize(gpu_inc_stop);
     if (error != cudaSuccess)
     {
          fprintf(stderr, "Failed to synchronize on the stop event (error code %s)!\n", cudaGetErrorString(error));
          exit(EXIT_FAILURE);
     }

     error = cudaEventElapsedTime(&inc_msecTotal, gpu_inc_start, gpu_inc_stop);
     if (error != cudaSuccess)
     {
          fprintf(stderr, "Failed to get time elapsed between events (error code %s)!\n", cudaGetErrorString(error));
          exit(EXIT_FAILURE);
     }

     printf("\t2 Matrix Transposes  + RowScan Only Exclusive Time: %f ms\n", mt2plusrs_excmsecTotal);
     printf("\tNN and II on GPU complete--> Combined Exclusive Time: %f ms, Total Inclusive time: %f ms\n", gpu_excmsecTotal, inc_msecTotal);

     //Destroy Events
     cudaEventDestroy(gpu_exc_start);
     cudaEventDestroy(gpu_exc_stop);
     cudaEventDestroy(gpu_inc_start);
     cudaEventDestroy(gpu_inc_stop);

     //Free resources
     cudaFree(device_srcimg.data);
     cudaFree(device_nnimg.data);
     cudaFree(d_sum.data);
     cudaFree(d_sqsum.data);
     cudaFree(transpose_dsum.data);
     cudaFree(transpose_dsqsum.data);
}
