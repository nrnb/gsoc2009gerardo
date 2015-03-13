/**************************************************************************************
Copyright (C) Apeksha Godiyal, 2008
Copyright (C) Gerardo Huck, 2009


This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.
You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.

See license.h for more information.
**************************************************************************************/
// GPLv3 License
#include "license.h"

// includes, system
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <math.h>
#include <cmath>
#include <ctime>

// includes, project
#include "cutil.h"
#include "GL/glut.h"
#include "cudpp.h"

// includes, kernels
#include <kernel.cu>

// Include other source files
#include "grap.cu"
#include "kdNode.cu"
#include "pkdNode.cu"
#include "common.h"
		       //#include "readFile.cu"
		       //#include "writeOutput.cu"
#include "scope.h"
#include "display.h"

// This function calculates one step of the force-driven layout process, updating the nodes position
void advancePositions(graph* currentGraph, globalScope *scope)
{
  cudaMemcpyToSymbol(gd, currentGraph, sizeof(graph));

  // Check if kernel execution generated and error
  CUT_CHECK_ERROR("Kernel execution failed");	
  
  for (int i = 0; i < currentGraph->numVertices; i++){
    scope->NodeTemp[i].x = currentGraph->NodePos[i].x;
    scope->NodeTemp[i].y = currentGraph->NodePos[i].y;
    scope->NodeTemp[i].z = i;
  }
  
  cudaMemcpy(scope->a, scope->NodeTemp, currentGraph->numVertices * sizeof(float3), cudaMemcpyHostToDevice);
  
  // Configure CUDPP Scan Plan
  CUDPPHandle planHandle;
  cudppPlan (&planHandle, scope->config, currentGraph->numVertices, 1, 0); // rows = 1, rowPitch = 0
  
  int sizeInt   = currentGraph->numVertices * sizeof(kdNodeInt);
  int sizeFloat = currentGraph->numVertices * sizeof(kdNodeFloat);
  
  // Check if the KDTREE has to be rebuilded
  if((currentGraph->currentIteration < 4) ||(currentGraph->currentIteration%20==0) ){

    // Decide whether the KDTREE is goint to be builded in the CPU or in the GPU
    if (currentGraph->numVertices < 50000){ //CPU
      kdNodeInit(scope->rootInt, scope->rootFloat, 1, 0, 0, SCREEN_W,0, SCREEN_H);
      construct(scope->NodeTemp, scope->NodeTemp + currentGraph->numVertices - 1, scope->rootInt, scope->rootFloat, 1, 0, 0, SCREEN_W, 0, SCREEN_H, 3);
    }
    else{                               //GPU   
      kdNodeInitD(scope->rootInt, scope->rootFloat, 1, 0, 0, SCREEN_W, 0, SCREEN_H);
      constructD(scope->a, scope->a + currentGraph->numVertices - 1, scope->rootInt, scope->rootFloat, 1, 0, 0, SCREEN_W, 0, SCREEN_H, 3, scope->data_out, scope->d_temp_addr_uint, scope->d_out, planHandle, scope->nD, scope->OuterD );
    }
  }
  	
  // Copy data to device
  cudaMemcpy (scope->NodePosD,   currentGraph->NodePos, (currentGraph->numVertices * sizeof(float2)), cudaMemcpyHostToDevice);
  cudaMemcpy (scope->treeIntD,   scope->rootInt,        sizeInt,                                      cudaMemcpyHostToDevice);
  cudaMemcpy (scope->treeFloatD, scope->rootFloat,      sizeFloat,                                    cudaMemcpyHostToDevice);

  cudaBindTexture (0, texNodePosD, scope->NodePosD,   (sizeof(float2) * currentGraph->numVertices));
  cudaBindTexture (0, texInt,      scope->treeIntD,   sizeInt                                     );
  cudaBindTexture (0, texFloat,    scope->treeFloatD, sizeFloat                                   );
  
  cudaMemcpy(scope->AdjMatIndexD, currentGraph->AdjMatIndex, (currentGraph->numVertices + 1) * sizeof(int), cudaMemcpyHostToDevice);
  cudaMemcpy(scope->AdjMatValsD,  currentGraph->AdjMatVals,  (currentGraph->numEdges)        * sizeof(int), cudaMemcpyHostToDevice);
  cudaMemcpy(scope->edgeLenD,     currentGraph->edgeLen,     (currentGraph->numEdges)        * sizeof(int), cudaMemcpyHostToDevice);

  // Check if kernel execution generated and error
  CUT_CHECK_ERROR("Kernel execution failed");
  
  cudaBindTexture (0, texAdjMatValsD, scope->AdjMatValsD, (currentGraph->numEdges) * sizeof(int));
  cudaBindTexture (0, texEdgeLenD,    scope->edgeLenD,    (currentGraph->numEdges) * sizeof(int));

  // Check if kernel execution generated and error
  CUT_CHECK_ERROR("Kernel execution failed");
    
  // Execute the kernel, calculate forces
  calculateForces<<< scope->blocks, scope->threads >>>(currentGraph->numVertices, scope->DispD, scope->AdjMatIndexD);
  
  // Check if kernel execution generated and error
  CUT_CHECK_ERROR("Kernel execution failed");

  cudaMemcpy(scope->Disp, scope->DispD, currentGraph->numVertices * sizeof(float2), cudaMemcpyDeviceToHost);
	
  // Calculate new positions of nodes, based on the force calculations
  for (int i = 0; i < currentGraph->numVertices; i++)
    calcPositions (i, currentGraph->NodePos, scope->Disp, currentGraph); 

  // Decrease the temperature of graph g
  cool(currentGraph, scope->initialNoIterations); 

  // Destroy CUDPP Scan Plan
  cudppDestroyPlan(planHandle);
}


// This function coarses a graph, by obtaining a maximal independant subset of it
graph* coarsen(graph *g, globalScope* scope)
{
  graph *	rg = (graph*) malloc(sizeof(graph));     // New graph which will hold the result of the coarsening
  bool *	used   = (bool*) calloc(g->numVertices,sizeof(bool));
  int *		newNodesNos = (int*) calloc(g->numVertices+1,sizeof(int));
  int		current = 0;
  int		left = g->numVertices;
  int		numParents = 0;

  rg->parent = (int*) calloc (g->numVertices, sizeof(int));
  
  while (left > 0){
    left--;
    newNodesNos[numParents] = current;
    rg->parent[current] = numParents;
    used[current] = 1;
    
    for (int x = g->AdjMatIndex[current]; x < g->AdjMatIndex[current+1]; x++){
      int j = g->AdjMatVals[x];
      if (!used[j])
	left --;
      used[j] = 1;
      rg->parent[j] = numParents;
    }
    numParents++;

    // If there is any node left, search for an unused one
    if (left>0)
      while ((used[current]))
	current++;
  }
  
  free(used);
  
  initGraph(rg,numParents);

  int numEdges = 0;
  rg->NodePos     = (float2 *) malloc((numParents)*sizeof(float2));
  rg->AdjMatIndex =  (int * )  calloc(numParents+1, sizeof(int));
  rg->AdjMatVals  =  (int * )  calloc(g->numEdges,  sizeof(int));
  rg->edgeLen     =  (float * )calloc(g->numEdges,  sizeof(float));
  
  for(int i = 0; i < numParents; i++){
    rg->NodePos[i].x = rand() % SCREEN_W;
    rg->NodePos[i].y = rand() % SCREEN_H;
  }
  
  for ( int i = 0; i < numParents; i++){
    int * usedChild = (int *) calloc(numParents,sizeof(int));
    int node = newNodesNos[i];
    for(int x = g->AdjMatIndex[node]; x < g->AdjMatIndex[node+1]; x++){
      int j = g->AdjMatVals[x];
      if (rg->parent[j] != i)
	usedChild[rg->parent[j]] = 1;
      else{
	for(int y = g->AdjMatIndex[j]; y < g->AdjMatIndex[j+1]; y++){
	  int neighbor = g->AdjMatVals[y];
	  usedChild[rg->parent[neighbor]] = 1;
	}
      }
    }
    
    for ( int k = 0; k < numParents; k++){
      if (usedChild[k]){
	rg->AdjMatVals[numEdges] = k;
	rg->edgeLen[numEdges] = scope->EDGE_LEN;
	numEdges++;
      }
    }
      
    rg->AdjMatIndex[i+1] = numEdges;
    free(usedChild);
  }  
  
  rg->numEdges = numEdges;
  return rg;
}


// This function just applies a one step advance to a graph position
void exactLayoutOnce(globalScope* scope, graph* currentGraph){
  advancePositions(currentGraph, scope);
}

// This funcion initializes a graph position, using the position of nodes in the coarsed graph (if it exists) as a guide
// It also deallocates the memory used by the coarsed graph
void nextLevelInitialization (graph g, graph* coarseGraph, globalScope* scope){
  
  // Nodes that exists in coarseGraph remain in the same position
  for (int i = 0; i < g.numVertices; i++){
    g.NodePos[i].x = coarseGraph->NodePos[coarseGraph->parent[i]].x ;
    g.NodePos[i].y = coarseGraph->NodePos[coarseGraph->parent[i]].y ;
  }
  
  
  for(int j = 0; j < scope->interpolationIterations; j++){
    for(int i = 0; i < g.numVertices; i++){
      int degree = g.AdjMatIndex[i+1] - g.AdjMatIndex[i];
      float2 pi; pi.x=0;pi.y=0;
      for(int k = g.AdjMatIndex[i]; k < g.AdjMatIndex[i+1]; k++){	
	int j = g.AdjMatVals[k];
	pi.x+=g.NodePos[j].x;
	pi.y+=g.NodePos[j].y;
      }
      if(degree){
	g.NodePos[i].x = 0.5 * ( g.NodePos[i].x+ (1.0/degree)*pi.x);
	g.NodePos[i].y = 0.5 * ( g.NodePos[i].y+ (1.0/degree)*pi.y);
      }
    }
  }
  
  free(coarseGraph->NodePos);
  free(coarseGraph->parent);
  free(coarseGraph->AdjMatIndex);
  free(coarseGraph->AdjMatVals);
  free(coarseGraph->edgeLen);
  free(coarseGraph);
}

// This function creates the MIS (Maximal Independent Set) Filtration of a graph
void createCoarseGraphs(graph* g, int level, globalScope* scope)
{
  scope->gArray[level] = g;
  if(g->numVertices <= scope->coarseGraphSize)
    return;
  
  graph *coarseGraph = coarsen(g, scope);
  
  if (g->numVertices < 1.07 * coarseGraph->numVertices )
    return;
  
  if(g->numVertices - coarseGraph->numVertices > 0 )
    createCoarseGraphs(coarseGraph, level + 1, scope);
}



int calculateLayout (globalScope* scope)
{
  
  // Initialize device, using macro defined in "cutil.h"
  CUT_DEVICE_INIT();

  /*    Initializations    */

  // Number of Nodes
  int  numNodes = (scope->g).numVertices;

  // Amount of memory to be used by integers
  int sizeInt = numNodes * sizeof(kdNodeInt);

  // Amount of memory to be used by floats
  int sizeFloat = numNodes * sizeof(kdNodeFloat);
  
  scope->rootInt   = (kdNodeInt*)   calloc(numNodes, sizeof(kdNodeInt)   );
  scope->rootFloat = (kdNodeFloat*) calloc(numNodes, sizeof(kdNodeFloat) );

  cudaMalloc ((void**) &(scope->treeIntD),   sizeInt                   );
  cudaMalloc ((void**) &(scope->treeFloatD), sizeFloat                 );
  cudaMalloc ((void**) &(scope->NodePosD),   numNodes * sizeof(float2) );
  
  // Check if kernel execution generated and error
  CUT_CHECK_ERROR("Kernel execution failed");
  
  // 
  scope->NodeTemp = (float3*) malloc(numNodes * sizeof(float3));
  cudaMalloc((void**) &(scope->a), numNodes * sizeof(float3));
  
  scope->Disp = (float2 *) malloc(numNodes * sizeof(float2));

  cudaMalloc ((void**) &(scope->DispD),        numNodes                     * sizeof(float2) );
  cudaMalloc ((void**) &(scope->AdjMatIndexD), ((scope->g).numVertices + 1) * sizeof(int)    );
  cudaMalloc ((void**) &(scope->AdjMatValsD),  (scope->g).numEdges          * sizeof(int)    );
  cudaMalloc ((void**) &(scope->edgeLenD),     (scope->g).numEdges          * sizeof(float)  );
  
  // Initialize parameters for config (see CUDPP in cudpp.h)
  (scope->config).algorithm = CUDPP_SCAN;
  (scope->config).op        = CUDPP_ADD;
  (scope->config).datatype  = CUDPP_INT;
  (scope->config).options   = CUDPP_OPTION_FORWARD | CUDPP_OPTION_EXCLUSIVE; 
  
  // Allocate memory in the Device for data used in CUDPP Scan
  cudaMalloc((void**) &(scope->data_out),         sizeof(unsigned int) * scope->g.numVertices);
  cudaMalloc((void**) &(scope->d_temp_addr_uint), sizeof(unsigned int) * scope->g.numVertices);
  cudaMalloc((void**) &(scope->d_out),            sizeof(float3)       * scope->g.numVertices);
  cudaMalloc((void**) &(scope->nD),               sizeof(unsigned int)                       );

  /*      END INITIALIZATIONS   */
  

  /*      GRAPH COARSENING      */
  //printf("Coarsening graph...\n");
  
  //clock_t start, end_coarsen,end_layout;
  //double elapsed_layout,elapsed_coarsen;

  //start = clock();
  
  (scope->gArray)[0] = &(scope->g);
  createCoarseGraphs(&(scope->g), 0, scope);
  scope->numLevels = 0;
  while((scope->gArray)[scope->numLevels] != NULL)
    (scope->numLevels)++;
  (scope->gArray)[scope->numLevels - 1]->level = 0;
  
  //end_coarsen = clock();

  //elapsed_coarsen = ((double) (end_coarsen - start)) / CLOCKS_PER_SEC;

  /*      END OF COARSENING      */


  /*      CALCULATE LAYOUTS      */

  //start = clock();
  //printf("Computing layout...\n");
  
  for(int i = 0; i < (scope->numLevels); i++){
    
    // setup execution parameters
    
    unsigned m_chunks    = (scope->gArray)[(scope->numLevels)-i-1]->numVertices / maxThreadsThisBlock;
    unsigned m_leftovers = (scope->gArray)[(scope->numLevels)-i-1]->numVertices % maxThreadsThisBlock;
    
    if ((m_chunks == 0) && (m_leftovers > 0)){
      // can't even fill a block
      scope->blocks  = dim3(1, 1, 1); 
      scope->threads = dim3(m_leftovers, 1, 1);
    } 
    else {
      // normal case
      if (m_leftovers > 0){
	// not aligned, add an additional block for leftovers
	scope->blocks = dim3(m_chunks + 1, 1, 1);
      }
      else{
	// aligned on block boundary
	scope->blocks = dim3(m_chunks, 1, 1);
      }
      scope->threads = dim3(maxThreadsThisBlock , 1, 1);
    }
    
    if(i < (scope->numLevels) - (scope->levelConvergence))
      while(!incrementsAreDone ((scope->gArray)[(scope->numLevels) - i - 1]))
	exactLayoutOnce(scope, (scope->gArray)[(scope->numLevels) - i - 1]);
  
    if((scope->numLevels) - i - 2 >= 0)                  
      nextLevelInitialization(*(scope->gArray)[(scope->numLevels) - i - 2], scope->gArray[(scope->numLevels) - i - 1], scope);
  }

  //end_layout = clock();
  //elapsed_layout = ((double) (end_layout - start)) / CLOCKS_PER_SEC;

  /*       END OF LAYOUT CALCULATION      */
  
  //printf ("Time for coarsening graph: %f\n", elapsed_coarsen);
  //printf ("Time for calculating layout: %f\n", elapsed_layout);
  
  // Release resorces
  cudaFree (scope->AdjMatIndexD);
  cudaFree (scope->edgeLenD);
  cudaFree (scope->AdjMatValsD);
  cudaFree (scope->NodePosD);
  cudaFree (scope->DispD);
  cudaFree (scope->treeIntD);
  cudaFree (scope->treeFloatD);
  cudaFree (scope->data_out);
  cudaFree (scope->d_temp_addr_uint);
  cudaFree (scope->d_out);
  cudaFree (scope->nD);
  free (scope->NodeTemp);
  free (scope->rootInt);
  free (scope->rootFloat);
  free (scope->Disp);

  // TODO: release gArray[]

  return 0;
}





