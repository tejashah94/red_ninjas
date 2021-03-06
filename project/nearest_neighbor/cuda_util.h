#ifndef __ERROR_HANDLE__H_
#define __ERROR_HANDLE__H_

#include <sys/time.h>
#include <stdio.h>
#include <stdint.h>
#include <iostream>
#include <fstream>
#include <cuda.h> //CUDA library

//DEBUG FLAGS
#define LOG 1
#define DEVICE 1

#define BLOCK_SIZE (16)             //16 x 16
#define ROWS_PER_TB (4)

using namespace std;


//DEBUG Varibales
#ifdef LOG
      static const bool PRINT_LOG = true;
#else
      static const bool PRINT_LOG = false;
#endif

#ifdef DEVICE
      static const bool PRINT_GPU = true;
#else
      static const bool PRINT_GPU = false;
#endif

//CUDA Error Checker -- If return value is -1 then there is an error
int CUDA_CHECK_RETURN(cudaError_t err_ret){

	int val = 0;
    if (err_ret != cudaSuccess) {
        fprintf(stderr, "Error %s at line %d in file %s\n", cudaGetErrorString(err_ret), __LINE__, __FILE__);   
        val = 1;
    }
    return val;    
} 																													

//compare the data stored in two arrays on the host
bool CompareResults(unsigned char* A, unsigned char* B, int elements){
   
   int diff = 0;   
   for(unsigned int i = 0; i < elements; i++){
       int error = abs(A[i]-B[i]);
       
       if(error > 0)
         diff++;
   }
   
   if(diff > 0)
      return false;
   else
      return true;
}

// Write a 16x16 floating point matrix to file
void WriteFile(unsigned char* data, int elements, std::fstream& ofs){

   for(unsigned int i = 0; i < elements; i++){
      ofs<<(data[i] - '0')<<" ";
   }
}


//Get smallest power 2 of a number
int getSmallestPower2(int num) {                                  
  int result = 1;                                                 
  while(result < num && result > 0)                               
    result <<= 1;                                                 
  if(result <= 0 || num <= 0) {                                   
    fprintf(stderr, "The size requested might be two large!\n");  
    exit(-1);                                                     
  }                                                               
  return result;                                                  
}                                       


#endif
