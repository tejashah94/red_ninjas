/*
 *  TU Eindhoven
 *  Eindhoven, The Netherlands
 *
 *  Name            :   haar.h
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

#ifndef __HAAR_H__
#define __HAAR_H__

#include <stdio.h>
#include <stdlib.h>
#include "image.h"
#include <vector>
#include "stdio-wrapper.h"

#define MAXLABELS 50
#define BLOCK_SIZE 1024

// defines for separate kernels
#define HAAR_KERN_0 323
#define NUMSTG_KERN_0 9
#define HAAR_KERN_1 323
#define NUMSTG_KERN_1 9
#define HAAR_KERN_2 323
#define NUMSTG_KERN_2 9
#define HAAR_KERN_3 323
#define NUMSTG_KERN_3 9
#define HAAR_KERN_4 323
#define NUMSTG_KERN_4 9
#define HAAR_KERN_5 323
#define NUMSTG_KERN_5 9
#define HAAR_KERN_6 323
#define NUMSTG_KERN_6 9
#define HAAR_KERN_7 323
#define NUMSTG_KERN_7 9
#define HAAR_KERN_8 323
#define NUMSTG_KERN_8 9
#define HAAR_KERN_9 323
#define NUMSTG_KERN_9 9

#ifdef __cplusplus
extern "C" {
#endif

typedef  int sumtype;
typedef int sqsumtype;

typedef struct MyPoint
{
    int x;
    int y;
}
MyPoint;

typedef struct
{
    int width;
    int height;
}
MySize;

typedef struct
{
    int x;
    int y;
    int width;
    int height;
}
MyRect;

typedef struct myCascade
{
// number of stages (22)
    int  n_stages;
    int total_nodes;
    float scale; 
 
    // size of the window used in the training set (20 x 20)
    MySize orig_window_size;
//    MySize real_window_size;

    int inv_window_area;

    MyIntImage sum;
    MyIntImage sqsum;
   
    // pointers to the corner of the actual detection window
    sqsumtype *pq0, *pq1, *pq2, *pq3;
    sumtype *p0, *p1, *p2, *p3;

} myCascade;



/* sets images for haar classifier cascade */
void setImageForCascadeClassifier( myCascade* cascade, MyIntImage* sum, MyIntImage* sqsum);

/* runs the cascade on the specified window */
int runCascadeClassifier( myCascade* cascade, MyPoint pt, int start_stage);

void readTextClassifier();//(myCascade* cascade);
void readTextClassifierForGPU();
void releaseTextClassifier();
void releaseTextClassifierGPU();


//void groupRectangles(MyRect* _vec, int groupThreshold, float eps);
void groupRectangles(std::vector<MyRect>& _vec, int groupThreshold, float eps);

/* draw white bounding boxes around detected faces */
void drawRectangle(MyImage* image, MyRect r);

//void detectObjects( MyImage* image, MySize minSize, MySize maxSize,
//		myCascade* cascade, MyRect *result,
//		float scale_factor,
//		int min_neighbors);

std::vector<MyRect> detectObjects( MyImage* image, MySize minSize, MySize maxSize,
		myCascade* cascade,
		float scale_factor,
		int min_neighbors);

// Function to check error for execution of CUDA APIs
void checkError();
void compare_bits(bool* ref, bool* data, int n);
#ifdef __cplusplus
}

#endif

#endif
