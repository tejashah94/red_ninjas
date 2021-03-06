#ifndef __NN_RS_KERNEL_H__                                                                        
#define __NN_RS_KERNEL_H__  

////////////////////////////
//32bit datatype kernels//
/////////////////////////

//NN + RowScan Kernel                                                                                                  
__global__ void rowscan_nn_kernel(unsigned char* src, int* sum, int* sqsum,                     
                                   int src_w, int src_h, int dst_w, int dst_h,                  
                                   int x_ratio, int y_ratio, int tb_elems)                      
{                                                                                                 
   volatile __shared__ int row[SHARED];                                                         
                                                                                                  
   //Nearest Neighbor Kernel                                                                    
   int tId = threadIdx.x;                                                                       
   int g_Idx = blockIdx.x * dst_w + tId;                                                        
                                                                                                
   int offset = 1;                                                                              
   int sq_start = tb_elems + 1;           //For square sum in Smem                              
   int offset_tId = tId + blockDim.x;                                                           
                                                                                                
   int row_src = (blockIdx.x * y_ratio) >> 16;                                                  
   int col1_src = (tId * x_ratio)  >> 16 ;                                                      
   int col2_src = ( (tId + blockDim.x) * x_ratio)  >> 16 ;                                      
                                                                                                
   //Populate shared memory row with down sampled pixels                                        
   row[tId] = src[row_src * src_w + col1_src];                                                  
                                                                                                
   if( (offset_tId) < dst_w){                                                                   
        row[offset_tId] = src[row_src * src_w + col2_src];                                      
   }else{                                                                                       
        row[offset_tId] = 0;                                                                    
   }                                                                                            
                                                                                           
   //Square of each elements in SMem                                                          
   row[sq_start + tId] = row[tId] * row[tId];                                                 
   row[sq_start + offset_tId] = row[offset_tId] * row[offset_tId];                            
                                                                                              
   //Upsweep                                                                                  
   for (int stage_threads = tb_elems>>1; stage_threads > 0; stage_threads >>= 1)              
   {                                                                                          
     __syncthreads();                                                                         
                                                                                              
     if (tId < stage_threads)                                                                 
     {                                                                                        
       int bi = offset * (2*tId+2) - 1;         //Each thread start                           
       int ai = offset * (2*tId+1) - 1;         //Neighbor or mate thread                     
                                                                                              
       row[bi] += row[ai];                                                                    
       row[sq_start + bi] += row[sq_start + ai];                                              
     }                                                                                        
                                                                                              
     offset <<= 1;                                                                            
   }                                                                                          
                                                                                              
   //DownSweep                                                                                
   if (tId == 0)                                                                              
   {                                                                                          
     row[tb_elems] = row[tb_elems - 1];          //For inclusive scan                         
     row[tb_elems - 1] = 0;                                                                   
     row[sq_start + tb_elems] = row[sq_start + tb_elems - 1];                                 
     row[sq_start + tb_elems - 1] = 0;                                                        
   }                                                                                          
                                                                                              
   for (int stage_threads = 1; stage_threads < tb_elems; stage_threads *= 2 )                 
   {                                                                                          
                                                                                              
     offset >>=1 ;                                                                            
     __syncthreads();                                                                         
                                                                                              
     if (tId < stage_threads)                                                                 
     {                                                                                        
                                                                                              
       int ai = offset * (2*tId+1) - 1;                                                       
       int bi = offset * (2*tId+2) - 1;                                                       
                                                                                              
       int dummy = row[ai];                      //Mate elements to dummy                     
       row[ai] = row[bi];                                                                     
       row[bi] += dummy;                                                                      
                                                                    
       int dummy_sq = row[sq_start + ai];                                           
       row[sq_start + ai] = row[sq_start + bi];                                     
       row[sq_start + bi] += dummy_sq;                                              
     }                                                                              
   }                                                                                
                                                                                    
   __syncthreads();                                                                 
                                                                                    
   sum[g_Idx] = row[tId + 1];                                                       
   sqsum[g_Idx] = row[sq_start + tId + 1];                                          
                                                                                    
   if (offset_tId < dst_w)                                                          
   {                                                                                
     sum[g_Idx + blockDim.x] = row[offset_tId + 1];                                 
     sqsum[g_Idx + blockDim.x] = row[sq_start + offset_tId + 1];                    
   }                                                                                
}                                                                                     


//Row Scan Only Kernel
__global__ void rowscan_only_kernel(int* sum, int* sqsum,                     
                                   int dst_w, int tb_elems)                      
{                                                                                                 
   volatile __shared__ int row_only[SHARED];                                                         
                                                                                                  
   //Nearest Neighbor Kernel                                                                    
   int tId = threadIdx.x;                                                                       
   int g_Idx = blockIdx.x * dst_w + tId;                                                        
                                                                                                
   int offset = 1;                                                                              
   int sq_start = tb_elems + 1;           //For square sum in Smem                              
   int offset_tId = tId + blockDim.x;                                                           
  
   row_only[tId] = sum[g_Idx] ;
   row_only[offset_tId] = offset_tId < dst_w ? sum[g_Idx + blockDim.x] : 0;
   row_only[sq_start + tId] =  sqsum[g_Idx];
   row_only[sq_start + offset_tId] =  offset_tId < dst_w ? sqsum[g_Idx + blockDim.x] : 0;

   //Upsweep                                                                                  
   for (int stage_threads = tb_elems>>1; stage_threads > 0; stage_threads >>= 1)              
   {                                                                                          
     __syncthreads();                                                                         
                                                                                              
     if (tId < stage_threads)                                                                 
     {                                                                                        
       int bi = offset * (2*tId+2) - 1;         //Each thread start                           
       int ai = offset * (2*tId+1) - 1;         //Neighbor or mate thread                     
                                                                                              
       row_only[bi] += row_only[ai];                                                                    
       row_only[sq_start + bi] += row_only[sq_start + ai];                                              
     }                                                                                        
                                                                                              
     offset <<= 1;                                                                            
   }                                                                                          
                                                                                              
   //DownSweep                                                                                
   if (tId == 0)                                                                              
   {                                                                                          
     row_only[tb_elems] = row_only[tb_elems - 1];          //For inclusive scan                         
     row_only[tb_elems - 1] = 0;                                                                   
     row_only[sq_start + tb_elems] = row_only[sq_start + tb_elems - 1];                                 
     row_only[sq_start + tb_elems - 1] = 0;                                                        
   }                                                                                          
                                                                                              
   for (int stage_threads = 1; stage_threads < tb_elems; stage_threads *= 2 )                 
   {                                                                                          
                                                                                              
     offset >>=1 ;                                                                            
     __syncthreads();                                                                         
                                                                                              
     if (tId < stage_threads)                                                                 
     {                                                                                        
                                                                                              
       int ai = offset * (2*tId+1) - 1;                                                       
       int bi = offset * (2*tId+2) - 1;                                                       
                                                                                              
       int dummy = row_only[ai];                      //Mate elements to dummy                     
       row_only[ai] = row_only[bi];                                                                     
       row_only[bi] += dummy;                                                                      
                                                                    
       int dummy_sq = row_only[sq_start + ai];                                           
       row_only[sq_start + ai] = row_only[sq_start + bi];                                     
       row_only[sq_start + bi] += dummy_sq;                                              
     }                                                                              
   }                                                                                
                                                                                    
   __syncthreads();                                                                 
                                                                                    
   sum[g_Idx] = row_only[tId + 1];                                                       
   sqsum[g_Idx] = row_only[sq_start + tId + 1];                                          
                                                                                    
   if (offset_tId < dst_w)                                                          
   {                                                                                
     sum[g_Idx + blockDim.x] = row_only[offset_tId + 1];                                 
     sqsum[g_Idx + blockDim.x] = row_only[sq_start + offset_tId + 1];                    
   }                                                                                
}

////////////////////////////
//16bit datatype kernels//
/////////////////////////

//NN + RowScan Kernel                                                                                                  
__global__ void rowscan_nn_kernel16_t(unsigned char* src, int16_t* sum, int16_t* sqsum,                     
                                   int src_w, int src_h, int dst_w, int dst_h,                  
                                   int x_ratio, int y_ratio, int tb_elems)                      
{                                                                                                 
   volatile __shared__ int16_t row16_t[SHARED];                                                         
                                                                                                  
   //Nearest Neighbor Kernel                                                                    
   int tId = threadIdx.x;                                                                       
   int g_Idx = blockIdx.x * dst_w + tId;                                                        
                                                                                                
   int offset = 1;                                                                              
   int sq_start = tb_elems + 1;           //For square sum in Smem                              
   int offset_tId = tId + blockDim.x;                                                           
                                                                                                
   int row_src = (blockIdx.x * y_ratio) >> 16;                                                  
   int col1_src = (tId * x_ratio)  >> 16 ;                                                      
   int col2_src = ( (tId + blockDim.x) * x_ratio)  >> 16 ;                                      
                                                                                                
   //Populate shared memory row with down sampled pixels                                        
   row16_t[tId] = src[row_src * src_w + col1_src];                                                  
                                                                                                
   if( (offset_tId) < dst_w){                                                                   
        row16_t[offset_tId] = src[row_src * src_w + col2_src];                                      
   }else{                                                                                       
        row16_t[offset_tId] = 0;                                                                    
   }                                                                                            
                                                                                           
   //Square of each elements in SMem                                                          
   row16_t[sq_start + tId] = row16_t[tId] * row16_t[tId];                                                 
   row16_t[sq_start + offset_tId] = row16_t[offset_tId] * row16_t[offset_tId];                            
                                                                                              
   //Upsweep                                                                                  
   for (int stage_threads = tb_elems>>1; stage_threads > 0; stage_threads >>= 1)              
   {                                                                                          
     __syncthreads();                                                                         
                                                                                              
     if (tId < stage_threads)                                                                 
     {                                                                                        
       int bi = offset * (2*tId+2) - 1;         //Each thread start                           
       int ai = offset * (2*tId+1) - 1;         //Neighbor or mate thread                     
                                                                                              
       row16_t[bi] += row16_t[ai];                                                                    
       row16_t[sq_start + bi] += row16_t[sq_start + ai];                                              
     }                                                                                        
                                                                                              
     offset <<= 1;                                                                            
   }                                                                                          
                                                                                              
   //DownSweep                                                                                
   if (tId == 0)                                                                              
   {                                                                                          
     row16_t[tb_elems] = row16_t[tb_elems - 1];          //For inclusive scan                         
     row16_t[tb_elems - 1] = 0;                                                                   
     row16_t[sq_start + tb_elems] = row16_t[sq_start + tb_elems - 1];                                 
     row16_t[sq_start + tb_elems - 1] = 0;                                                        
   }                                                                                          
                                                                                              
   for (int stage_threads = 1; stage_threads < tb_elems; stage_threads *= 2 )                 
   {                                                                                          
                                                                                              
     offset >>=1 ;                                                                            
     __syncthreads();                                                                         
                                                                                              
     if (tId < stage_threads)                                                                 
     {                                                                                        
                                                                                              
       int ai = offset * (2*tId+1) - 1;                                                       
       int bi = offset * (2*tId+2) - 1;                                                       
                                                                                              
       int16_t dummy = row16_t[ai];                      //Mate elements to dummy                     
       row16_t[ai] = row16_t[bi];                                                                     
       row16_t[bi] += dummy;                                                                      
                                                                    
       int16_t dummy_sq = row16_t[sq_start + ai];                                           
       row16_t[sq_start + ai] = row16_t[sq_start + bi];                                     
       row16_t[sq_start + bi] += dummy_sq;                                              
     }                                                                              
   }                                                                                
                                                                                    
   __syncthreads();                                                                 
                                                                                    
   sum[g_Idx] = row16_t[tId + 1];                                                       
   sqsum[g_Idx] = row16_t[sq_start + tId + 1];                                          
                                                                                    
   if (offset_tId < dst_w)                                                          
   {                                                                                
     sum[g_Idx + blockDim.x] = row16_t[offset_tId + 1];                                 
     sqsum[g_Idx + blockDim.x] = row16_t[sq_start + offset_tId + 1];                    
   }                                                                                
}                                                                                     


//Row Scan Only Kernel
__global__ void rowscan_only_kernel16_t(int16_t* sum, int16_t* sqsum,                     
                                   int dst_w, int tb_elems)                      
{                                                                                                 
   volatile __shared__ int16_t row16_t_only[SHARED];                                                         
                                                                                                  
   //Nearest Neighbor Kernel                                                                    
   int tId = threadIdx.x;                                                                       
   int g_Idx = blockIdx.x * dst_w + tId;                                                        
                                                                                                
   int offset = 1;                                                                              
   int sq_start = tb_elems + 1;           //For square sum in Smem                              
   int offset_tId = tId + blockDim.x;                                                           
  
   row16_t_only[tId] = sum[g_Idx] ;
   row16_t_only[offset_tId] = offset_tId < dst_w ? sum[g_Idx + blockDim.x] : 0;
   row16_t_only[sq_start + tId] =  sqsum[g_Idx];
   row16_t_only[sq_start + offset_tId] =  offset_tId < dst_w ? sqsum[g_Idx + blockDim.x] : 0;

   //Upsweep                                                                                  
   for (int stage_threads = tb_elems>>1; stage_threads > 0; stage_threads >>= 1)              
   {                                                                                          
     __syncthreads();                                                                         
                                                                                              
     if (tId < stage_threads)                                                                 
     {                                                                                        
       int bi = offset * (2*tId+2) - 1;         //Each thread start                           
       int ai = offset * (2*tId+1) - 1;         //Neighbor or mate thread                     
                                                                                              
       row16_t_only[bi] += row16_t_only[ai];                                                                    
       row16_t_only[sq_start + bi] += row16_t_only[sq_start + ai];                                              
     }                                                                                        
                                                                                              
     offset <<= 1;                                                                            
   }                                                                                          
                                                                                              
   //DownSweep                                                                                
   if (tId == 0)                                                                              
   {                                                                                          
     row16_t_only[tb_elems] = row16_t_only[tb_elems - 1];          //For inclusive scan                         
     row16_t_only[tb_elems - 1] = 0;                                                                   
     row16_t_only[sq_start + tb_elems] = row16_t_only[sq_start + tb_elems - 1];                                 
     row16_t_only[sq_start + tb_elems - 1] = 0;                                                        
   }                                                                                          
                                                                                              
   for (int stage_threads = 1; stage_threads < tb_elems; stage_threads *= 2 )                 
   {                                                                                          
                                                                                              
     offset >>=1 ;                                                                            
     __syncthreads();                                                                         
                                                                                              
     if (tId < stage_threads)                                                                 
     {                                                                                        
                                                                                              
       int ai = offset * (2*tId+1) - 1;                                                       
       int bi = offset * (2*tId+2) - 1;                                                       
                                                                                              
       int16_t dummy = row16_t_only[ai];                      //Mate elements to dummy                     
       row16_t_only[ai] = row16_t_only[bi];                                                                     
       row16_t_only[bi] += dummy;                                                                      
                                                                    
       int16_t dummy_sq = row16_t_only[sq_start + ai];                                           
       row16_t_only[sq_start + ai] = row16_t_only[sq_start + bi];                                     
       row16_t_only[sq_start + bi] += dummy_sq;                                              
     }                                                                              
   }                                                                                
                                                                                    
   __syncthreads();                                                                 
                                                                                    
   sum[g_Idx] = row16_t_only[tId + 1];                                                       
   sqsum[g_Idx] = row16_t_only[sq_start + tId + 1];                                          
                                                                                    
   if (offset_tId < dst_w)                                                          
   {                                                                                
     sum[g_Idx + blockDim.x] = row16_t_only[offset_tId + 1];                                 
     sqsum[g_Idx + blockDim.x] = row16_t_only[sq_start + offset_tId + 1];                    
   }                                                                                
}


#endif                                                               
                                                                     
                                                                     
                                                                                    
                                                                                          


