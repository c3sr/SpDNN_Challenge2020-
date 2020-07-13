#include "vars.h"
#include <cuda.h>

extern int neuron;
extern int layer;
extern int batch;
extern int input;
extern float bias;

extern int **csrdispl;
extern INDPREC **csrindex;
extern VALPREC **csrvalue;

extern FEATPREC *currfeat;
extern FEATPREC *nextfeat;
extern int *active;
extern int *categories;
extern int *globalcategories;

extern double timeio;
extern double timetot;
extern double timeinfer;
extern double *timeactive;
extern double *timeidle;
extern double *timecomm;

extern int myid;
extern int numproc;
extern int numthreads;

extern int *numbatch;
extern int *batchdispl;
extern int mybatch;
extern int extbatch;

int **csrdispl_d;
INDPREC **csrindex_d;
VALPREC **csrvalue_d;

int **buffdispl;
int **mapdispl;
int **map;
int **warpdispl;
INDPREC **warpindex;
VALPREC **warpvalue;

int **buffdispl_d;
int **mapdispl_d;
int **map_d;
int **warpdispl_d;
INDPREC *warpindex_d;
VALPREC *warpvalue_d;

FEATPREC *currfeat_d;
FEATPREC *nextfeat_d;
int *active_d;
int *categories_d;

int blocksize;
int numblocks;
int numwarp;
int buffsize;

cudaEvent_t start, stop;
float elapsedTime;

__device__ float __ReLU(float x){
   return x<0.0?0.0:x>32.0?32.0:x;
};

__global__ void __launch_bounds__(256,4) dummy_kernel(FEATPREC *nextfeat, FEATPREC *currfeat, int buffsize, int *buffdispl, int *mapdispl, int *map, int *displ, INDPREC *index, VALPREC *value, float bias , int neuron, int *categories, int *active){
  extern __shared__ float shared[];
  int wind = threadIdx.x%WARPSIZE;
  float reduce[MINIBATCH] = {0.0};
  for(int buff = buffdispl[blockIdx.x]; buff < buffdispl[blockIdx.x+1]; buff++){
    int mapnz = mapdispl[buff+1]-mapdispl[buff];
    for(int n = threadIdx.x; n < mapnz; n += blockDim.x){
      int ind = map[mapdispl[buff]+n];
      for(int f = 0; f < MINIBATCH; f++)
        shared[f*buffsize+n] = currfeat[categories[blockIdx.y*MINIBATCH+f]*neuron+ind];
    }
    __syncthreads();
    int warp = (buff*blockDim.x+threadIdx.x)/WARPSIZE;
    for(int m = displ[warp]; m < displ[warp+1]; m++){
      int ind = index[m*WARPSIZE+wind];
      float val = value[m*WARPSIZE+wind];
      for(int f = 0; f < MINIBATCH; f++)
        reduce[f] += shared[f*buffsize+ind]*val;
    }
    __syncthreads();
  }
  int m = blockIdx.x*blockDim.x+threadIdx.x;
  for(int f = 0; f < MINIBATCH; f++)
    if(nextfeat[(blockIdx.y*MINIBATCH+f)*neuron+m]=__ReLU(reduce[f]+bias))
      atomicAdd(active+blockIdx.y*MINIBATCH+f,1);
};

void setup_gpu(){

  cudaSetDevice(myid%6);
  printf("myid %d mydevice %d\n",myid,myid%4);
  cudaFuncSetAttribute(dummy_kernel,cudaFuncAttributeMaxDynamicSharedMemorySize,98304);
  if(myid==0){
    int deviceCount;
    cudaGetDeviceCount(&deviceCount);
    printf("\n");
    printf("Device Count: %d\n",deviceCount);
    int dev = 0;
    cudaDeviceProp deviceProp;
    cudaGetDeviceProperties(&deviceProp, dev);
    printf("Device %d name: %s\n",dev,deviceProp.name);
    printf("Computational Capabilities: %d, %d\n",deviceProp.major,deviceProp.minor);
    printf("Maximum global memory size: %lu\n",deviceProp.totalGlobalMem);
    printf("Maximum constant memory size: %lu\n",deviceProp.totalConstMem);
    printf("Maximum shared memory size per block: %lu\n",deviceProp.sharedMemPerBlock);
    printf("Maximum block dimensions: %dx%dx%d\n",deviceProp.maxThreadsDim[0],deviceProp.maxThreadsDim[1],deviceProp.maxThreadsDim[2]);
    printf("Maximum grid dimensions: %dx%dx%d\n",deviceProp.maxGridSize[0],deviceProp.maxGridSize[1],deviceProp.maxGridSize[2]);
    printf("Maximum threads per block: %d\n",deviceProp.maxThreadsPerBlock);
    printf("Warp size: %d\n",deviceProp.warpSize);
    printf("\n");
  }

  char *chartemp;
  chartemp = getenv("BLOCKSIZE");
  blocksize = atoi(chartemp);
  chartemp = getenv("BUFFER");
  buffsize = atoi(chartemp)*1024/sizeof(float)/MINIBATCH;
  numblocks = neuron/blocksize;
  numwarp = blocksize/32;
  if(myid==0){
    printf("BLOCK SIZE: %d\n",blocksize);
    printf("NUM BLOCKS: %d\n",numblocks);
    printf("NUMWARPS: %d\n",numwarp);
    printf("BUFFER SIZE PER FEATURE: %d (%f KB)\n",buffsize,buffsize*sizeof(float)/1024.0);
    printf("BUFFER SIZE: %d (%f KB)\n",buffsize*MINIBATCH,buffsize*sizeof(float)/1024.0*MINIBATCH);
  }

  preproc();

  double memother = 0.0;
  cudaMallocHost((void**)&globalcategories,sizeof(int)*mybatch);
  cudaMallocHost((void**)&categories,sizeof(int)*mybatch);
  cudaMallocHost((void**)&active,sizeof(int)*mybatch);
  cudaMalloc((void**)&active_d,sizeof(int)*extbatch);
  cudaMalloc((void**)&categories_d,sizeof(int)*extbatch);
  memother += sizeof(int)*extbatch/1.0e9;
  memother += sizeof(int)*extbatch/1.0e9;
  for(int k = 0; k < mybatch; k++){
    active[k] = neuron;
    categories[k] = k;
    globalcategories[k] = batchdispl[myid]+k;
  }
  cudaMemset(active_d,0,sizeof(int)*extbatch);
  cudaMemset(categories_d,0,sizeof(int)*extbatch);
  cudaMemcpy(active_d,active,sizeof(int)*mybatch,cudaMemcpyHostToDevice);
  cudaMemcpy(categories_d,categories,sizeof(int)*mybatch,cudaMemcpyHostToDevice);

  if(myid==0)printf("INDPREC,VALPREC\n");

  double memweight = 0.0;
  double memdispl = 0.0;
  double memmap = 0.0;
  buffdispl_d = new int*[layer];
  mapdispl_d = new int*[layer];
  map_d = new int*[layer];
  warpdispl_d = new int*[layer];
  //warpindex_d = new INDPREC*[layer];
  //warpvalue_d = new VALPREC*[layer];
  int streamsize = 0;
  for(int l = 0; l < layer; l++){
    cudaMalloc((void**)&buffdispl_d[l],sizeof(int)*(numblocks+1));
    cudaMalloc((void**)&mapdispl_d[l],sizeof(int)*(buffdispl[l][numblocks]+1));
    cudaMalloc((void**)&map_d[l],sizeof(int)*(mapdispl[l][buffdispl[l][numblocks]]));
    cudaMalloc((void**)&warpdispl_d[l],sizeof(int)*(buffdispl[l][numblocks]*numwarp+1));
    //cudaMalloc((void**)&warpindex_d[l],sizeof(INDPREC)*warpdispl[l][buffdispl[l][numblocks]*numwarp]*WARPSIZE);
    //cudaMalloc((void**)&warpvalue_d[l],sizeof(VALPREC)*warpdispl[l][buffdispl[l][numblocks]*numwarp]*WARPSIZE);
    memdispl += sizeof(int)*(numblocks+1)/1.0e9;
    memdispl += sizeof(int)*(buffdispl[l][numblocks]+1)/1.0e9;
    memmap += sizeof(int)*(mapdispl[l][buffdispl[l][numblocks]])/1.0e9;
    memdispl += sizeof(int)*(buffdispl[l][numblocks]*numwarp+1)/1.0e9;
    //memweight += sizeof(INDPREC)*warpdispl[l][buffdispl[l][numblocks]*numwarp]*WARPSIZE/1.0e9;
    //memweight += sizeof(VALPREC)*warpdispl[l][buffdispl[l][numblocks]*numwarp]*WARPSIZE/1.0e9;
    cudaMemcpy(buffdispl_d[l],buffdispl[l],sizeof(int)*(numblocks+1),cudaMemcpyHostToDevice);
    cudaMemcpy(mapdispl_d[l],mapdispl[l],sizeof(int)*(buffdispl[l][numblocks]+1),cudaMemcpyHostToDevice);
    cudaMemcpy(map_d[l],map[l],sizeof(int)*(mapdispl[l][buffdispl[l][numblocks]]),cudaMemcpyHostToDevice);
    cudaMemcpy(warpdispl_d[l],warpdispl[l],sizeof(int)*(buffdispl[l][numblocks]*numwarp+1),cudaMemcpyHostToDevice);
    if(warpdispl[l][buffdispl[l][numblocks]*numwarp]*WARPSIZE>streamsize)
      streamsize = warpdispl[l][buffdispl[l][numblocks]*numwarp]*WARPSIZE;
    //cudaMemcpy(warpindex_d[l],warpindex[l],sizeof(INDPREC)*warpdispl[l][buffdispl[l][numblocks]*numwarp]*WARPSIZE,cudaMemcpyHostToDevice);
    //cudaMemcpy(warpvalue_d[l],warpvalue[l],sizeof(VALPREC)*warpdispl[l][buffdispl[l][numblocks]*numwarp]*WARPSIZE,cudaMemcpyHostToDevice);
  }
  if(myid==0)
    printf("streamsize: %d (%f KB)\n",streamsize,(sizeof(INDPREC)+sizeof(VALPREC))*streamsize/1.0e6);
  cudaMalloc((void**)&warpindex_d,sizeof(INDPREC)*streamsize);
  cudaMalloc((void**)&warpvalue_d,sizeof(VALPREC)*streamsize);
  memweight += sizeof(INDPREC)*streamsize/1.0e9;
  memweight += sizeof(VALPREC)*streamsize/1.0e9;

  double memfeat = 0.0;
  cudaMalloc((void**)&currfeat_d,sizeof(FEATPREC)*extbatch*neuron);
  cudaMalloc((void**)&nextfeat_d,sizeof(FEATPREC)*extbatch*neuron);
  memfeat += sizeof(FEATPREC)*extbatch*neuron/1.0e9;
  memfeat += sizeof(FEATPREC)*extbatch*neuron/1.0e9;
  cudaMemset(currfeat_d,0,sizeof(FEATPREC)*extbatch*neuron);
  cudaMemset(nextfeat_d,0,sizeof(FEATPREC)*extbatch*neuron);
  cudaMemcpy(currfeat_d,currfeat,sizeof(FEATPREC)*mybatch*neuron,cudaMemcpyHostToDevice);

  double memothers[numproc];
  double memweights[numproc];
  double memdispls[numproc];
  double memmaps[numproc];
  double memfeats[numproc];
  MPI_Allgather(&memother,1,MPI_DOUBLE,memothers,1,MPI_DOUBLE,MPI_COMM_WORLD);
  MPI_Allgather(&memweight,1,MPI_DOUBLE,memweights,1,MPI_DOUBLE,MPI_COMM_WORLD);
  MPI_Allgather(&memdispl,1,MPI_DOUBLE,memdispls,1,MPI_DOUBLE,MPI_COMM_WORLD);
  MPI_Allgather(&memmap,1,MPI_DOUBLE,memmaps,1,MPI_DOUBLE,MPI_COMM_WORLD);
  MPI_Allgather(&memfeat,1,MPI_DOUBLE,memfeats,1,MPI_DOUBLE,MPI_COMM_WORLD);
  if(myid==0){
    double memmax = 0.0;
    for(int p = 0; p < numproc; p++){
      double memtot = memdispls[p]+memmaps[p]+memweights[p]+memfeats[p];
      printf("GPU %d: OTHERS: %f DISPLS: %f MAPS: %f WEIGHTS: %f FEATURES: %f TOTAL: %f GB\n",p,memothers[p],memdispls[p],memmaps[p],memweights[p],memfeats[p],memtot);
      if(memtot>memmax)memmax=memtot;
    }
    printf("MAX GPU MEM: %f GB\n",memmax);
  }
  cudaEventCreate(&start);
  cudaEventCreate(&stop);
}

void infer_gpu(int l){
  extern double timekernel;
  extern double timestream;
  dim3 block(blocksize);
  dim3 grid(numblocks,(mybatch+MINIBATCH-1)/MINIBATCH);

  double streamtime = MPI_Wtime();
  int streamsize = warpdispl[l][buffdispl[l][numblocks]*numwarp]*WARPSIZE;
  cudaMemcpy(warpindex_d,warpindex[l],sizeof(INDPREC)*streamsize,cudaMemcpyHostToDevice);
  cudaMemcpy(warpvalue_d,warpvalue[l],sizeof(VALPREC)*streamsize,cudaMemcpyHostToDevice);
  timestream += MPI_Wtime()-streamtime;

  cudaMemset(active_d,0,sizeof(int)*mybatch);

  cudaEventRecord(start);
  dummy_kernel<<<grid,block,sizeof(float)*buffsize*MINIBATCH>>>(nextfeat_d,currfeat_d,buffsize,buffdispl_d[l],mapdispl_d[l],map_d[l],warpdispl_d[l],warpindex_d,warpvalue_d,bias,neuron,categories_d,active_d);
  cudaEventRecord(stop);
  cudaEventSynchronize(stop);
  cudaEventElapsedTime(&elapsedTime,start,stop);
  timekernel += elapsedTime/1.0e3;

  cudaMemcpy(active,active_d,sizeof(int)*mybatch,cudaMemcpyDeviceToHost);

  int feature = 0;
  for(int k = 0; k < mybatch; k++)
    if(active[k]){
      globalcategories[feature] = globalcategories[k];
      categories[feature] = k;
      feature++;
    }

  cudaMemcpy(categories_d,categories,sizeof(int)*feature,cudaMemcpyHostToDevice);

  FEATPREC *tempfeat_d = currfeat_d;
  currfeat_d = nextfeat_d;
  nextfeat_d = tempfeat_d;

  /*int allfeature = 0;
  MPI_Allreduce(&feature,&allfeature,1,MPI_INT,MPI_SUM,MPI_COMM_WORLD);
  if(myid==0)printf("layer %d features %d\n",l,allfeature);*/

  mybatch = feature;
};
void preproc(){
  buffdispl = new int*[layer];
  mapdispl = new int*[layer];
  map = new int*[layer];
  warpdispl = new int*[layer];
  warpindex = new INDPREC*[layer];
  warpvalue = new VALPREC*[layer];
  int totbuff = 0;
  int totmapnz = 0;
  int totwarpnz = 0;
  int *temptag = new int[neuron*numthreads];
  for(int l = 0; l < layer; l++){
    //if(myid==0)printf("preprocessing layer %d\n",l);
    int *numbuff = new int[numblocks];
    buffdispl[l] = new int[numblocks+1];
    #pragma omp parallel for
    for(int b = 0; b < numblocks; b++){
      int *temp = temptag+omp_get_thread_num()*neuron;
      for(int n = 0; n < neuron; n++)
        temp[n] = 0;
      for(int m = b*blocksize; m < (b+1)*blocksize; m++)
        for(int n = csrdispl[l][m]; n < csrdispl[l][m+1]; n++)
          temp[csrindex[l][n]]++;
      int footprint = 0;
      for(int n = 0; n < neuron; n++){
        if(temp[n])
          footprint++;
      }
      numbuff[b] = (footprint+buffsize-1)/buffsize;
    }
    buffdispl[l][0] = 0;
    for(int b = 0; b < numblocks; b++)
      buffdispl[l][b+1] = buffdispl[l][b]+numbuff[b];
    totbuff += buffdispl[l][numblocks];
    int *warpnz = new int[buffdispl[l][numblocks]*numwarp];
    #pragma omp parallel for
    for(int n = 0; n < buffdispl[l][numblocks]*numwarp; n++)
      warpnz[n] = 0;
    int *mapnz = new int[buffdispl[l][numblocks]];
    #pragma omp parallel for
    for(int n = 0; n < buffdispl[l][numblocks]; n++)
      mapnz[n] = 0;
    #pragma omp parallel for
    for(int b = 0; b < numblocks; b++){
      int *temp = temptag+omp_get_thread_num()*neuron;
      for(int n = 0; n < neuron; n++)
        temp[n] = 0;
      for(int m = b*blocksize; m < (b+1)*blocksize; m++)
        for(int n = csrdispl[l][m]; n < csrdispl[l][m+1]; n++)
          temp[csrindex[l][n]]++;
      int footprint = 0;
      for(int n = 0; n < neuron; n++)
        if(temp[n]){
          int buff = footprint/buffsize;
          mapnz[buffdispl[l][b]+buff]++;
          temp[n] = buff;
          footprint++;
        }
      for(int buff = 0; buff < numbuff[b]; buff++)
        for(int warp = 0; warp < numwarp; warp++){
          int tempnz[WARPSIZE] = {0};
          for(int t = 0; t < WARPSIZE; t++)
            for(int n = csrdispl[l][b*blocksize+warp*WARPSIZE+t]; n < csrdispl[l][b*blocksize+warp*WARPSIZE+t+1]; n++)
              if(temp[csrindex[l][n]]==buff)
                 tempnz[t]++;
          int warpmax = 0;
          for(int t = 0; t < WARPSIZE; t++)
            if(tempnz[t]>warpmax)
              warpmax = tempnz[t];
          warpnz[(buffdispl[l][b]+buff)*numwarp+warp] = warpmax;
        }
    }
    warpdispl[l] = new int[buffdispl[l][numblocks]*numwarp+1];
    warpdispl[l][0] = 0;
    for(int warp = 0; warp < buffdispl[l][numblocks]*numwarp; warp++)
      warpdispl[l][warp+1] = warpdispl[l][warp]+warpnz[warp];
    totwarpnz += warpdispl[l][buffdispl[l][numblocks]*numwarp];
    cudaMallocHost((void**)&warpindex[l],sizeof(INDPREC)*warpdispl[l][buffdispl[l][numblocks]*numwarp]*WARPSIZE);
    cudaMallocHost((void**)&warpvalue[l],sizeof(VALPREC)*warpdispl[l][buffdispl[l][numblocks]*numwarp]*WARPSIZE);
    //warpindex[l] = new INDPREC[warpdispl[l][buffdispl[l][numblocks]*numwarp]*WARPSIZE];
    //warpvalue[l] = new VALPREC[warpdispl[l][buffdispl[l][numblocks]*numwarp]*WARPSIZE];
    #pragma omp parallel for
    for(int n = 0; n < warpdispl[l][buffdispl[l][numblocks]*numwarp]*WARPSIZE; n++){
      warpindex[l][n] = 0;
      warpvalue[l][n] = 0.0;
    }
    mapdispl[l] = new int[buffdispl[l][numblocks]+1];
    mapdispl[l][0] = 0;
    for(int buff = 0; buff < buffdispl[l][numblocks]; buff++)
      mapdispl[l][buff+1] = mapdispl[l][buff] + mapnz[buff];
    totmapnz += mapdispl[l][buffdispl[l][numblocks]];
    map[l] = new int[mapdispl[l][buffdispl[l][numblocks]]];
    #pragma omp parallel for
    for(int n = 0; n < buffdispl[l][numblocks]; n++)
      mapnz[n] = 0;
    #pragma omp parallel for
    for(int b = 0; b < numblocks; b++){
      int *temp = temptag+omp_get_thread_num()*neuron;
      for(int n = 0; n < neuron; n++)
        temp[n] = 0;
      for(int m = b*blocksize; m < (b+1)*blocksize; m++)
        for(int n = csrdispl[l][m]; n < csrdispl[l][m+1]; n++)
          temp[csrindex[l][n]]++;
      int footprint = 0;
      for(int n = 0; n < neuron; n++)
        if(temp[n]){
          int buff = footprint/buffsize;
          map[l][mapdispl[l][buffdispl[l][b]+buff]+mapnz[buffdispl[l][b]+buff]] = n;
          mapnz[buffdispl[l][b]+buff]++;
          temp[n] = footprint;
          footprint++;
        }
      for(int buff = 0; buff < numbuff[b]; buff++)
        for(int warp = 0; warp < numwarp; warp++){
          int tempnz[WARPSIZE] = {0};
          for(int t = 0; t < WARPSIZE; t++)
            for(int n = csrdispl[l][b*blocksize+warp*WARPSIZE+t]; n < csrdispl[l][b*blocksize+warp*WARPSIZE+t+1]; n++)
              if(temp[csrindex[l][n]]/buffsize==buff){
                 int ind = (warpdispl[l][(buffdispl[l][b]+buff)*numwarp+warp]+tempnz[t])*WARPSIZE+t;
                 warpindex[l][ind] = temp[csrindex[l][n]]%buffsize;
                 warpvalue[l][ind] = csrvalue[l][n];
                 tempnz[t]++;
              }
        }
    }
    delete[] numbuff;
    delete[] mapnz;
    delete[] warpnz;
    delete[] csrdispl[l];
    delete[] csrindex[l];
    delete[] csrvalue[l];
  }
  delete[] temptag;
  delete[] csrdispl;
  delete[] csrindex;
  delete[] csrvalue;
  if(myid==0)printf("total buffers: %d (%f per block)\n",totbuff,totbuff/(float)layer/numblocks);
  if(myid==0)printf("total map: %d (%f per block)\n",totmapnz,totmapnz/(float)layer/numblocks);
  if(myid==0)printf("total warpnz: %d (%f per buffer)\n",totwarpnz,totwarpnz/(float)totbuff);
  if(myid==0)printf("iefficiency: %f\n",totwarpnz*(float)WARPSIZE/(layer*(float)neuron*32));
  /*if(myid==0)
    for(int l = 0; l < 5; l++)
      for(int buff = 0; buff < 15; buff++)
        for(int warp = 0; warp < numwarp; warp++){
          int nz = warpdispl[l][buff*numwarp+warp+1]-warpdispl[l][buff*numwarp+warp];
          printf("Layer %d buff %d warp %d nz %d\n",l,buff,buff*numwarp+warp,nz);
          for(int m = warpdispl[l][buff*numwarp+warp]; m < warpdispl[l][buff*numwarp+warp+1]; m++){
            for(int t = 0; t < WARPSIZE; t++)
              printf("%e ",__half2float(warpvalue[l][m*WARPSIZE+t]));
            printf("\n");
          }
      }*/
};

