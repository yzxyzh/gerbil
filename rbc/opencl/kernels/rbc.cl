typedef float real;
typedef uint unint;

#define DEBUG

#ifdef DEBUG
#define assert(x) \
            if (! (x)) \
            { \
                printf((__constant char*)"Assert(%s) failed in line: %d\n", \
                       (__constant char*)#x, __LINE__); \
            }
#else
        #define assert(X)
#endif

#define BLOCK_SIZE 16
#define SCAN_WIDTH 1024

#define KMAX 32 //Internal parameter.  Do not change!

//Row major indexing
#define IDX(i,j,ld) (((size_t)(i)*(ld))+(j))

#define DIST(i,j) (((i) - (j)) * ((i) - (j))) // L_2

#define MAX(a,b) max(a,b)
#define MIN(a,b) min(a,b)

#define MAXi(i,j,k,l) ((i) > (j) ? (k) : (l)) //indexed version
#define MINi(i,j,k,l) ((i) <= (j) ? (k) : (l))

#define DUMMY_IDX UINT_MAX

//Computes all pairs of distances between Q and X.

//typedef struct {
//  real *mat;
//  unint r; //rows
//  unint c; //cols
//  unint pr; //padded rows
//  unint pc; //padded cols
//  unint ld; //the leading dimension (in this code, this is the same as pc)
//} matrix;


__kernel void dist1Kernel(__global const real* Q_mat,
                         unint Q_r,
                         unint Q_c,
                         unint Q_pr,
                         unint Q_pc,
                         unint Q_ld,
                         unint qStart,
                         __global const real* X_mat,
                         unint X_r,
                         unint X_c,
                         unint X_pr,
                         unint X_pc,
                         unint X_ld,
                         unint xStart,
                         __global real* D_mat,
                         unint D_r,
                         unint D_c,
                         unint D_pr,
                         unint D_pc,
                         unint D_ld,
                         unint dq_offset)
{
    unint c, i, j;

    size_t threadIdx_x = get_local_id(0);
    size_t threadIdx_y = get_local_id(1);

    size_t blockIdx_x = get_group_id(0);
    size_t blockIdx_y = get_group_id(1);

    unint qB = blockIdx_y*BLOCK_SIZE + qStart;
    unint q  = threadIdx_y;
    unint xB = blockIdx_x*BLOCK_SIZE + xStart;
    unint x = threadIdx_x;

    real ans=0;

    //This thread is responsible for computing the dist between Q[qB+q] and X[xB+x]

    __local real Qs[BLOCK_SIZE][BLOCK_SIZE];
    __local real Xs[BLOCK_SIZE][BLOCK_SIZE];

    for(i=0 ; i<Q_pc/BLOCK_SIZE; i++)
    {
        c=i*BLOCK_SIZE; //current col block

        Qs[x][q] = Q_mat[ dq_offset + IDX(qB+q, c+x, Q_ld) ];
        Xs[x][q] = X_mat[ IDX(xB+q, c+x, X_ld) ];

        barrier(CLK_LOCAL_MEM_FENCE);

        for(j=0 ; j<BLOCK_SIZE ; j++)
            ans += DIST( Qs[j][q], Xs[j][x] );

        barrier(CLK_LOCAL_MEM_FENCE);
    }

    D_mat[ IDX( qB+q, xB+x, D_ld ) ] = ans;
}


//This function is used by the rbc building routine.  It find an appropriate range
//such that roughly cntWant points fall within this range.  D is a matrix of distances.
__kernel void findRangeKernel(__global const real* D_mat,
                              unint D_r,
                              unint D_c,
                              unint D_pr,
                              unint D_pc,
                              unint D_ld,
                              unint numDone,
                              __global real* ranges,
                              unint cntWant,
                              unint offset)
{

    size_t blockIdx_y = get_group_id(1);

    size_t threadIdx_x = get_local_id(0);
    size_t threadIdx_y = get_local_id(1);

    unint row = blockIdx_y*(BLOCK_SIZE/4)+threadIdx_y + numDone;
    unint ro = threadIdx_y;
    unint co = threadIdx_x;
    unint i;
    real t;

    const unint LB = (90 * cntWant) / 100;
    const unint UB = cntWant;

    __local real smin[BLOCK_SIZE/4][4*BLOCK_SIZE];
    __local real smax[BLOCK_SIZE/4][4*BLOCK_SIZE];

    //  real min= MAX_REAL;
    real min_val = FLT_MAX;
    real max_val = 0;

    for(unint c = 0 ; c < D_pc; c += (4*BLOCK_SIZE))
    {
        if(c + co < D_c)
        {
            t = D_mat[IDX( row, c+co, D_ld )];
            min_val = MIN(t,min_val);
            max_val = MAX(t,max_val);
        }
    }

    smin[ro][co] = min_val;
    smax[ro][co] = max_val;

    barrier(CLK_LOCAL_MEM_FENCE);

    for(i = 2 * BLOCK_SIZE; i > 0; i /= 2)
    {
        if(co < i)
        {
            smin[ro][co] = MIN(smin[ro][co], smin[ro][co+i]);
            smax[ro][co] = MAX(smax[ro][co], smax[ro][co+i]);
        }
        barrier(CLK_LOCAL_MEM_FENCE);
    }

    //Now start range counting.

    unint itcount = 0;
    real rg;

    __local unint scnt[BLOCK_SIZE/4][4*BLOCK_SIZE];
    __local char cont[BLOCK_SIZE/4];

    if(co==0)
        cont[ro]=1;

    do
    {
        itcount++;

        barrier(CLK_LOCAL_MEM_FENCE);

        if(cont[ro])  //if we didn't actually need to cont, leave rg as it was.
            rg = ( smax[ro][0] + smin[ro][0] ) / ((real)2.0) ;

        unint cnt = 0;

        for(unint c = 0; c < D_pc; c += (4*BLOCK_SIZE))
        {
            cnt += (c+co < D_c && row < D_r
                               && D_mat[ IDX( row, c+co, D_ld ) ] <= rg);
        }

        scnt[ro][co] = cnt;

        barrier(CLK_LOCAL_MEM_FENCE);

        for(i = 2 * BLOCK_SIZE; i > 0; i /= 2)
        {
            if(co < i)
            {
                scnt[ro][co] += scnt[ro][co+i];
            }
            barrier(CLK_LOCAL_MEM_FENCE);
        }

        if(co == 0)
        {
            if(scnt[ro][0] < cntWant)
                smin[ro][0]=rg;
            else
                smax[ro][0]=rg;
        }

        // cont[ro] == this row needs to continue
        if(co == 0)
            cont[ro] = row<D_r && ( scnt[ro][0] < LB || scnt[ro][0] > UB );

        barrier(CLK_LOCAL_MEM_FENCE);

        // Determine if *any* of the rows need to continue
        for(i = BLOCK_SIZE / 8; i > 0; i /= 2)
        {
            if(ro < i && co == 0)
                cont[ro] |= cont[ro+i];
            barrier(CLK_LOCAL_MEM_FENCE);
        }

    } while(cont[0]);

    if(co == 0 && row < D_r)
        ranges[row + offset] = rg;
}


__kernel void rangeSearchKernel(__global const real* D_mat,
                                unint D_r,
                                unint D_c,
                                unint D_pr,
                                unint D_pc,
                                unint D_ld,
                                unint xOff,
                                unint yOff,
                                __global const real *ranges,
                                __global char* ir_mat,
                                unint ir_r,
                                unint ir_c,
                                unint ir_pr,
                                unint ir_pc,
                                unint ir_ld)
{
    size_t threadIdx_x = get_local_id(0);
    size_t threadIdx_y = get_local_id(1);

    size_t blockIdx_x = get_group_id(0);
    size_t blockIdx_y = get_group_id(1);

    unint col = blockIdx_x*BLOCK_SIZE + threadIdx_x + xOff;
    unint row = blockIdx_y*BLOCK_SIZE + threadIdx_y + yOff;

    ir_mat[IDX( row, col, ir_ld )] = D_mat[IDX( row, col, D_ld )] < ranges[row];
}

/** Performs parallel scan for chunks of size SCAN_WIDTH
  * in_mat - matrix of binary values
  * sum_mat - matrix of exclusive prefix sums
  * sumaux_mat - contains the last values from each scan for every row
  *
  * e.g: if row has 4 * SCAN_WIDTH elements, 4 partial scans will be performed,
  *      sumaux_mat will have 4 columns and the same number of rows as in_mat
  */
__kernel void sumKernel(__global const char* in_mat,
                       unint in_r,
                       unint in_c,
                       unint in_pr,
                       unint in_pc,
                       unint in_ld,
                       __global unint* sum_mat,
                       unint sum_r,
                       unint sum_c,
                       unint sum_pr,
                       unint sum_pc,
                       unint sum_ld,
                       __global unint* sumaux_mat,
                       unint sumaux_r,
                       unint sumaux_c,
                       unint sumaux_pr,
                       unint sumaux_pc,
                       unint sumaux_ld,
                       unint n)
{

  size_t blockIdx_x = get_group_id(0);
  size_t blockIdx_y = get_group_id(1);

  unint id = get_local_id(0);
  unint bo = blockIdx_x*SCAN_WIDTH; //block offset
  unint r = blockIdx_y;
  unint d, t;

  const unint l=SCAN_WIDTH; //length

  unint off=1;

  __local unint ssum[SCAN_WIDTH];

  ssum[2*id] = (bo+2*id < n) ? in_mat[IDX( r, bo+2*id, in_ld )] : 0;
  ssum[2*id+1] = (bo+2*id+1 < n) ? in_mat[IDX( r, bo+2*id+1, in_ld)] : 0;

  //up-sweep
  for( d=l>>1; d > 0; d>>=1 ){

    barrier(CLK_LOCAL_MEM_FENCE);

    if( id < d ){
      ssum[ off*(2*id+2)-1 ] += ssum[ off*(2*id+1)-1 ];
    }
    off *= 2;
  }

  barrier(CLK_LOCAL_MEM_FENCE);

  if ( id == 0 ){
    sumaux_mat[IDX( r, blockIdx_x, sumaux_ld )] = ssum[ l-1 ];
    ssum[ l-1 ] = 0;
  }

  //down-sweep
  for ( d=1; d<l; d*=2 ){
    off >>= 1;

    barrier(CLK_LOCAL_MEM_FENCE);

    if( id < d ){
      t = ssum[ off*(2*id+1)-1 ];
      ssum[ off*(2*id+1)-1 ] = ssum[ off*(2*id+2)-1 ];
      ssum[ off*(2*id+2)-1 ] += t;
    }
  }

  barrier(CLK_LOCAL_MEM_FENCE);

  if( bo+2*id < n )
    sum_mat[IDX( r, bo+2*id, sum_ld )] = ssum[2*id];
  if( bo+2*id+1 < n )
    sum_mat[IDX( r, bo+2*id+1, sum_ld )] = ssum[2*id+1];
}

__kernel void sumKernelI(__global const unint* in_mat,
                       unint in_r,
                       unint in_c,
                       unint in_pr,
                       unint in_pc,
                       unint in_ld,
                       __global unint* sum_mat,
                       unint sum_r,
                       unint sum_c,
                       unint sum_pr,
                       unint sum_pc,
                       unint sum_ld,
                       __global unint* sumaux_mat,
                       unint sumaux_r,
                       unint sumaux_c,
                       unint sumaux_pr,
                       unint sumaux_pc,
                       unint sumaux_ld,
                       unint n)
{

  size_t blockIdx_x = get_group_id(0);
  size_t blockIdx_y = get_group_id(1);

  unint id = get_local_id(0);
  unint bo = blockIdx_x*SCAN_WIDTH; //block offset
  unint r = blockIdx_y;
  unint d, t;

  const unint l=SCAN_WIDTH; //length

  unint off=1;

  __local unint ssum[SCAN_WIDTH];

  ssum[2*id] = (bo+2*id < n) ? in_mat[IDX( r, bo+2*id, in_ld )] : 0;
  ssum[2*id+1] = (bo+2*id+1 < n) ? in_mat[IDX( r, bo+2*id+1, in_ld)] : 0;

  //up-sweep
  for( d=l>>1; d > 0; d>>=1 ){

    barrier(CLK_LOCAL_MEM_FENCE);

    if( id < d ){
      ssum[ off*(2*id+2)-1 ] += ssum[ off*(2*id+1)-1 ];
    }
    off *= 2;
  }

  barrier(CLK_LOCAL_MEM_FENCE);

  if ( id == 0 ){
    sumaux_mat[IDX( r, blockIdx_x, sumaux_ld )] = ssum[ l-1 ];
    ssum[ l-1 ] = 0;
  }

  //down-sweep
  for ( d=1; d<l; d*=2 ){
    off >>= 1;

    barrier(CLK_LOCAL_MEM_FENCE);

    if( id < d ){
      t = ssum[ off*(2*id+1)-1 ];
      ssum[ off*(2*id+1)-1 ] = ssum[ off*(2*id+2)-1 ];
      ssum[ off*(2*id+2)-1 ] += t;
    }
  }

  barrier(CLK_LOCAL_MEM_FENCE);

  if( bo+2*id < n )
    sum_mat[IDX( r, bo+2*id, sum_ld )] = ssum[2*id];
  if( bo+2*id+1 < n )
    sum_mat[IDX( r, bo+2*id+1, sum_ld )] = ssum[2*id+1];
}


__kernel void combineSumKernel(__global unint* sum_mat,
                                unint sum_r,
                                unint sum_c,
                                unint sum_pr,
                                unint sum_pc,
                                unint sum_ld,
                                unint numDone,
                                __global const unint* daux_mat,
                                unint daux_r,
                                unint daux_c,
                                unint daux_pr,
                                unint daux_pc,
                                unint daux_ld,
                                unint n)
{
    unint id = get_local_id(0);

    size_t blockIdx_x = get_group_id(0);
    size_t blockIdx_y = get_group_id(1);

    unint bo = blockIdx_x * SCAN_WIDTH;
    unint r = blockIdx_y + numDone;

    if(bo+2*id < n)
    {
        sum_mat[IDX(r, bo + 2 * id, sum_ld)]
                          += daux_mat[IDX(r, blockIdx_x, daux_ld)];
    }
    if(bo+2*id+1 < n)
    {
        sum_mat[IDX(r, bo + 2 * id + 1, sum_ld)]
                          += daux_mat[IDX(r, blockIdx_x, daux_ld)];
    }

}

/** Creates lists of indexes of nearests neighbours for every row
  *  map - output matrix
  *  ir - binary mask
  *  sums - prefix sums
  */
__kernel void buildMapKernel(__global unint* map_mat,
                            unint map_r,
                            unint map_c,
                            unint map_pr,
                            unint map_pc,
                            unint map_ld,
                            __global const char* ir_mat,
                            unint ir_r,
                            unint ir_c,
                            unint ir_pr,
                            unint ir_pc,
                            unint ir_ld,
                            __global const unint* sums_mat,
                            unint sums_r,
                            unint sums_c,
                            unint sums_pr,
                            unint sums_pc,
                            unint sums_ld,
                            unint offSet)
{
    unint id = get_local_id(0);

    size_t blockIdx_x = get_group_id(0);
    size_t blockIdx_y = get_group_id(1);

    unint bo = blockIdx_x * SCAN_WIDTH;
    unint r = blockIdx_y;

    if(bo+2*id < ir_c && ir_mat[IDX( r, bo+2*id, ir_ld )])
    {
        map_mat[IDX(r+offSet, sums_mat[IDX(r, bo+2*id, sums_ld)], map_ld)] = bo+2*id;
    }

    if(bo+2*id+1 < ir_c && ir_mat[IDX( r, bo+2*id+1, ir_ld )])
    {
        map_mat[IDX( r+offSet, sums_mat[IDX( r, bo+2*id+1, sums_ld )], map_ld)] = bo+2*id+1;
    }
}

__kernel void getCountsKernel(__global unint *counts,
                              unint numDone,
                              __global char* ir_mat,
                              unint ir_r,
                              unint ir_c,
                              unint ir_pr,
                              unint ir_pc,
                              unint ir_ld,
                              __global unint* sums_mat,
                              unint sums_r,
                              unint sums_c,
                              unint sums_pr,
                              unint sums_pc,
                              unint sums_ld)
{
    size_t threadIdx_x = get_local_id(0);
    size_t blockIdx_x = get_group_id(0);

    unint r = blockIdx_x*BLOCK_SIZE + threadIdx_x + numDone;
    if (r < ir_r)
    {
        int val = sums_mat[IDX(r, sums_c-1, sums_ld)];
        counts[r] = ir_mat[IDX( r, ir_c-1, ir_ld )] ? val + 1 : val;
    }
}


/**The basic 1-NN search kernel.
  * Q - query matrix
  * X - representatives matrix
  * dMins - output distances
  * dMinIDs - output indexes
  */
__kernel void nnKernel(__global const real* Q_mat,
                        unint Q_r,
                        unint Q_c,
                        unint Q_pr,
                        unint Q_pc,
                        unint Q_ld,
                        unint numDone,
                        __global const real* X_mat,
                        unint X_r,
                        unint X_c,
                        unint X_pr,
                        unint X_pc,
                        unint X_ld,
                        __global real* dMins,
                        __global unint* dMinIDs)
{
    size_t blockIdx_y = get_group_id(1);

    unint qB = blockIdx_y * BLOCK_SIZE + numDone;  //indexes Q
    unint xB; //indexes X;
    unint cB; //colBlock
    unint offQ = get_local_id(1); //the offset of qPos in this block
    unint offX = get_local_id(0); //ditto for x
    unint i;
    real ans;

    __local real min_val[BLOCK_SIZE][BLOCK_SIZE];
    __local unint minPos[BLOCK_SIZE][BLOCK_SIZE];

    __local real Xs[BLOCK_SIZE][BLOCK_SIZE];
    __local real Qs[BLOCK_SIZE][BLOCK_SIZE];

    //min[offQ][offX]=MAX_REAL;
    min_val[offQ][offX] = FLT_MAX;

    barrier(CLK_LOCAL_MEM_FENCE);

    for(xB = 0; xB < X_pr; xB += BLOCK_SIZE)
    {
        ans = 0;

        for(cB = 0; cB < X_pc; cB += BLOCK_SIZE)
        {
            //Each thread loads one element of X and Q into memory.
            Xs[offX][offQ] = X_mat[IDX(xB + offQ, cB + offX, X_ld)];
            Qs[offX][offQ] = Q_mat[IDX(qB + offQ, cB + offX, Q_ld)];

            barrier(CLK_LOCAL_MEM_FENCE);

            for(i = 0; i < BLOCK_SIZE; i++)
                ans += DIST(Xs[i][offX], Qs[i][offQ]);

            barrier(CLK_LOCAL_MEM_FENCE);
        }

        if(xB + offX < X_r && ans < min_val[offQ][offX])
        {
            minPos[offQ][offX] = xB + offX;
            min_val[offQ][offX] = ans;
        }
    }

    barrier(CLK_LOCAL_MEM_FENCE);

    //reduce across threads
    for(i = BLOCK_SIZE / 2; i > 0; i /= 2)
    {
        if(offX < i)
        {
            if(min_val[offQ][offX+i]<min_val[offQ][offX])
            {
                min_val[offQ][offX] = min_val[offQ][offX+i];
                minPos[offQ][offX] = minPos[offQ][offX+i];
            }
        }
        barrier(CLK_LOCAL_MEM_FENCE);
    }

    if(offX == 0)
    {
        dMins[qB+offQ] = min_val[offQ][0];
        dMinIDs[qB+offQ] = minPos[offQ][0];
    }
}


//min-max gate: it sets the minimum of x and y into x, the maximum into y, and
//exchanges the indices (xi and yi) accordingly.
void mmGateI(__local real *x, __local real *y,
             __local unint *xi, __local unint *yi)
{
    unint ti = MINi( *x, *y, *xi, *yi );
    *yi = MAXi( *x, *y, *xi, *yi );
    *xi = ti;
    real t = MIN( *x, *y );
    *y = MAX( *x, *y );
    *x = t;
}

/** This is the same as sort16, but takes as input lists of length 48
  * and sorts the last 16 entries.  This cleans up some of the NN code,
  * though it is inelegant.
  */
void sort16off(__local real x[][48], __local unint xi[][48])
{
    int i = get_local_id(0);
    int j = get_local_id(1);

    if(i % 2 == 0)
        mmGateI(x[j] + KMAX + i, x[j] + KMAX + i + 1,
                xi[j] + KMAX + i, xi[j] + KMAX + i + 1);

    barrier(CLK_LOCAL_MEM_FENCE);

    if(i % 4 < 2)
        mmGateI(x[j] + KMAX + i, x[j] + KMAX + i + 2,
                xi[j] + KMAX + i, xi[j] + KMAX + i + 2);

    barrier(CLK_LOCAL_MEM_FENCE);

    if(i%4==1)
        mmGateI( x[j]+KMAX+i, x[j]+KMAX+i+1, xi[j]+KMAX+i, xi[j]+KMAX+i+1 );

    barrier(CLK_LOCAL_MEM_FENCE);

    if(i%8<4)
        mmGateI( x[j]+KMAX+i, x[j]+KMAX+i+4, xi[j]+KMAX+i, xi[j]+KMAX+i+4 );

    barrier(CLK_LOCAL_MEM_FENCE);

    if(i%8==2 || i%8==3)
        mmGateI( x[j]+KMAX+i, x[j]+KMAX+i+2, xi[j]+KMAX+i, xi[j]+KMAX+i+2 );

    barrier(CLK_LOCAL_MEM_FENCE);

    if( i%2 && i%8 != 7 )
         mmGateI( x[j]+KMAX+i, x[j]+KMAX+i+1, xi[j]+KMAX+i, xi[j]+KMAX+i+1 );

    barrier(CLK_LOCAL_MEM_FENCE);

    //0-7; 8-15 now sorted.  merge time.
    if( i<8)
        mmGateI( x[j]+KMAX+i, x[j]+KMAX+i+8, xi[j]+KMAX+i, xi[j]+KMAX+i+8 );

    barrier(CLK_LOCAL_MEM_FENCE);

    if( i>3 && i<8 )
        mmGateI( x[j]+KMAX+i, x[j]+KMAX+i+4, xi[j]+KMAX+i, xi[j]+KMAX+i+4 );

    barrier(CLK_LOCAL_MEM_FENCE);

    int os = (i/2)*4+2 + i%2;
    if(i<6)
        mmGateI( x[j]+KMAX+os, x[j]+KMAX+os+2, xi[j]+KMAX+os, xi[j]+KMAX+os+2 );

    barrier(CLK_LOCAL_MEM_FENCE);

    if( i%2 && i<15)
        mmGateI( x[j]+KMAX+i, x[j]+KMAX+i+1, xi[j]+KMAX+i, xi[j]+KMAX+i+1 );
}


/** This function takes an array of lists, each of length 48. It is assumed
  * that the first 32 numbers are sorted, and the last 16 numbers.  The
  * routine then merges these lists into one sorted list of length 48.
  */
void merge32x16(__local real x[][48], __local unint xi[][48]){

    int i = get_local_id(0);
    int j = get_local_id(1);

    mmGateI( x[j]+i, x[j]+i+32, xi[j]+i, xi[j]+i+32 );

    barrier(CLK_LOCAL_MEM_FENCE);

    mmGateI( x[j]+i+16, x[j]+i+32, xi[j]+i+16, xi[j]+i+32 );

    barrier(CLK_LOCAL_MEM_FENCE);

    int os = (i<8)? 24: 0;
    mmGateI( x[j]+os+i, x[j]+os+i+8, xi[j]+os+i, xi[j]+os+i+8 );

    barrier(CLK_LOCAL_MEM_FENCE);

    os = (i/4)*8+4 + i%4;
    mmGateI( x[j]+os, x[j]+os+4, xi[j]+os, xi[j]+os+4 );

    if(i<4)
        mmGateI(x[j]+36+i, x[j]+36+i+4, xi[j]+36+i, xi[j]+36+i+4 );

    barrier(CLK_LOCAL_MEM_FENCE);

    os = (i/2)*4+2 + i%2;
    mmGateI( x[j]+os, x[j]+os+2, xi[j]+os, xi[j]+os+2 );

    os = (i/2)*4+34 + i%2;
    if(i<6)
        mmGateI( x[j]+os, x[j]+os+2, xi[j]+os, xi[j]+os+2 );

    barrier(CLK_LOCAL_MEM_FENCE);

    os = 2*i+1;
    mmGateI(x[j]+os, x[j]+os+1, xi[j]+os, xi[j]+os+1 );

    os = 2*i+33;
    if(i<7)
        mmGateI(x[j]+os, x[j]+os+1, xi[j]+os, xi[j]+os+1 );
}


//This is indentical to the planNNkernel, except that it maintains a list of 32-NNs.  At
//each iteration-chunk, the next 16 distances are computed, then sorted, then merged
//with the previously computed 32-NNs.
__kernel void planKNNKernel(__global const real* Q_mat,
                            unint Q_r,
                            unint Q_c,
                            unint Q_pr,
                            unint Q_pc,
                            unint Q_ld,
                            __global const unint* qMap,
                            __global const real* X_mat,
                            unint X_r,
                            unint X_c,
                            unint X_pr,
                            unint X_pc,
                            unint X_ld,
                            __global const unint* xMap_mat,
                            unint xMap_r,
                            unint xMap_c,
                            unint xMap_pr,
                            unint xMap_pc,
                            unint xMap_ld,
                            __global real* dMins_mat,
                            unint dMins_r,
                            unint dMins_c,
                            unint dMins_pr,
                            unint dMins_pc,
                            unint dMins_ld,
                            __global unint* dMinIDs_mat,
                            unint dMinIDs_r,
                            unint dMinIDs_c,
                            unint dMinIDs_pr,
                            unint dMinIDs_pc,
                            unint dMinIDs_ld,
                            __global const unint* cP_numGroups,
                            __global const unint* cP_groupCountX,
                            __global const unint* cP_qToQGroup,
                            __global const unint* cP_qGroupToXGroup,
                            unint cP_ld,
                            unint qStartPos)
{

    size_t threadIdx_x = get_local_id(0);
    size_t threadIdx_y = get_local_id(1);

    size_t blockIdx_x = get_group_id(0);
    size_t blockIdx_y = get_group_id(1);

    unint qB = qStartPos + blockIdx_y * BLOCK_SIZE;  //indexes Q
    unint xB; //X (DB) Block;
    unint cB; //column Block
    unint offQ = threadIdx_y; //the offset of qPos in this block
    unint offX = threadIdx_x; //ditto for x

    __local real dNN[BLOCK_SIZE][KMAX + BLOCK_SIZE];
    __local unint idNN[BLOCK_SIZE][KMAX + BLOCK_SIZE];

    __local real Xs[BLOCK_SIZE][BLOCK_SIZE];
    __local real Qs[BLOCK_SIZE][BLOCK_SIZE];

    unint g = cP_qToQGroup[qB]; /** query group of q */
    unint numGroups = cP_numGroups[g]; /** always 1 in case of identity matrix */

    dNN[offQ][offX] = FLT_MAX;//MAX_REAL;
    dNN[offQ][offX + 16] = FLT_MAX;//MAX_REAL;
    idNN[offQ][offX] = DUMMY_IDX;
    idNN[offQ][offX + 16] = DUMMY_IDX;

    barrier(CLK_LOCAL_MEM_FENCE);

    for(unint i = 0; i < numGroups; i++) //iterate over DB groups
    {
        //DB group currently being examined
        unint xG = cP_qGroupToXGroup[IDX(g, i, cP_ld)];
        unint groupCount = cP_groupCountX[IDX(g, i, cP_ld)];

        unint groupIts = (groupCount + BLOCK_SIZE - 1) / BLOCK_SIZE;

        for(unint j = 0; j < groupIts; j++) //iterate over elements of group
        {
            xB = j * BLOCK_SIZE;
            real ans = 0;

            /** iterate over cols to compute distances */
            for(cB = 0; cB < X_pc; cB += BLOCK_SIZE)
            {
                unint databaseIdx = IDX(xMap_mat[IDX(xG, xB + offQ, xMap_ld)],
                                        cB + offX, X_ld);

                unint queryIdx = IDX(qMap[qB+offQ], cB+offX, Q_ld);

                Xs[offX][offQ] = X_mat[databaseIdx];
                Qs[offX][offQ] = ((qMap[qB + offQ] == DUMMY_IDX)
                                                        ? 0 : Q_mat[queryIdx]);
                barrier(CLK_LOCAL_MEM_FENCE);

                for(unint k = 0; k < BLOCK_SIZE; k++)
                    ans += DIST(Xs[k][offX], Qs[k][offQ]);

                barrier(CLK_LOCAL_MEM_FENCE);
            }

            dNN[offQ][offX+32] = (xB + offX < groupCount) ? ans : FLT_MAX;

            idNN[offQ][offX+32] = (xB + offX < groupCount)
                            ? xMap_mat[IDX(xG, xB + offX, xMap_ld)] : DUMMY_IDX;

            barrier(CLK_LOCAL_MEM_FENCE);

            /** sorting the last 16 items of 48 */
            sort16off(dNN, idNN);

            barrier(CLK_LOCAL_MEM_FENCE);

            /** merging the last 16 items with first 32 items into
              * one sorted array of 48 items */
            merge32x16(dNN, idNN);
        }
    }

    barrier(CLK_LOCAL_MEM_FENCE);

    if(qMap[qB + offQ] != DUMMY_IDX)
    {
        int out_idx = IDX(qMap[qB + offQ], offX, dMins_ld);

        dMins_mat[out_idx] = dNN[offQ][offX];
        dMins_mat[out_idx + 16] = dNN[offQ][offX + 16];

        out_idx = IDX(qMap[qB + offQ], offX, dMinIDs_ld);

        dMinIDs_mat[out_idx] = idNN[offQ][offX];
        dMinIDs_mat[out_idx + 16] = idNN[offQ][offX + 16];

    }
}

//Computes the 32-NNs for each query in Q.  It is similar to nnKernel above, but maintains a
//list of the 32 currently-closest points in the DB, instead of just the single NN.  After each
//batch of 16 points is processed, it sorts these 16 points according to the distance from the
//query, then merges this list with the other list.
/** Brute search for 32 nns */
__kernel void nn32Kernel(__global const real* Q_mat,
                        unint Q_r,
                        unint Q_c,
                        unint Q_pr,
                        unint Q_pc,
                        unint Q_ld,
                        unint numDone,
                        __global const real* X_mat,
                        unint X_r,
                        unint X_c,
                        unint X_pr,
                        unint X_pc,
                        unint X_ld,
                        __global real* dMins_mat,
                        unint dMins_r,
                        unint dMins_c,
                        unint dMins_pr,
                        unint dMins_pc,
                        unint dMins_ld,
                        __global unint* dMinIDs_mat,
                        unint dMinIDs_r,
                        unint dMinIDs_c,
                        unint dMinIDs_pr,
                        unint dMinIDs_pc,
                        unint dMinIDs_ld)
{
  //unint qB = blockIdx.y * BLOCK_SIZE + numDone;  //indexes Q

    unint qB = get_group_id(1) * BLOCK_SIZE + numDone;  //indexes Q

    unint xB; //indexes X;
    unint cB; //colBlock
    unint offQ = get_local_id(1);//threadIdx.y; //the offset of qPos in this block
    unint offX = get_local_id(0);//threadIdx.x; //ditto for x
    unint i;
    real ans;

    __local real Xs[BLOCK_SIZE][BLOCK_SIZE];
    __local real Qs[BLOCK_SIZE][BLOCK_SIZE];

    __local real dNN[BLOCK_SIZE][KMAX+BLOCK_SIZE];
    __local unint idNN[BLOCK_SIZE][KMAX+BLOCK_SIZE];

    dNN[offQ][offX] = FLT_MAX;//MAX_REAL;
    dNN[offQ][offX+16] = FLT_MAX;//MAX_REAL;
    idNN[offQ][offX] = DUMMY_IDX;
    idNN[offQ][offX+16] = DUMMY_IDX;

    barrier(CLK_LOCAL_MEM_FENCE);

    for(xB = 0; xB < X_pr; xB += BLOCK_SIZE)
    {
        ans=0;

        for(cB=0; cB < X_pc; cB += BLOCK_SIZE)
        {

            //Each thread loads one element of X and Q into memory.
            Xs[offX][offQ] = X_mat[IDX(xB + offQ, cB + offX, X_ld)];
            Qs[offX][offQ] = Q_mat[IDX(qB + offQ, cB + offX, Q_ld)];

            barrier(CLK_LOCAL_MEM_FENCE);

            for(i = 0; i < BLOCK_SIZE; i++)
                ans += DIST(Xs[i][offX], Qs[i][offQ]);

            barrier(CLK_LOCAL_MEM_FENCE);
        }

        //dNN[offQ][offX+32] = (xB+offX<X.r)? ans:MAX_REAL;
        dNN[offQ][offX + 32] = (xB + offX < X_r) ? ans : FLT_MAX;
        idNN[offQ][offX + 32] = xB + offX;

        barrier(CLK_LOCAL_MEM_FENCE);

        sort16off(dNN, idNN);

        barrier(CLK_LOCAL_MEM_FENCE);

        merge32x16(dNN, idNN);
    }

    barrier(CLK_LOCAL_MEM_FENCE);

    dMins_mat[IDX(qB + offQ, offX, dMins_ld)] = dNN[offQ][offX];
    dMins_mat[IDX(qB + offQ, offX + 16, dMins_ld)] = dNN[offQ][offX + 16];
    dMinIDs_mat[IDX(qB + offQ, offX, dMins_ld)] = idNN[offQ][offX];
    dMinIDs_mat[IDX(qB + offQ, offX + 16, dMins_ld)] = idNN[offQ][offX + 16];
}

#define PILOT_BLOCK_SIZE_X 32
#define PILOT_BLOCK_SIZE_Y 8
#define PILOT_POINTS_PER_ROW 4

__kernel void computePilotKernel(__global const float* nns,
                                 int width, int height,
                                 int neighbours_num,
                                 int neighbours_pitch,
                                 float threshold,
                                 __global int* result)
{
    size_t x = get_global_id(0);
    size_t y = get_global_id(1);

    size_t local_id_x = get_local_id(0);
    size_t local_id_y = get_local_id(1);

    size_t nns_base_group = y * width + x * PILOT_POINTS_PER_ROW;

    __local int counters[PILOT_BLOCK_SIZE_Y][PILOT_BLOCK_SIZE_Y];

    for(int i = 0; i < PILOT_POINTS_PER_ROW; ++i)
    {
        counters[local_id_y][local_id_x] = 0;

        __global const float* current_nns
                            = nns + ((nns_base_group + i) * neighbours_pitch);

        /** testing each neigbour from the list */
        for(int j = 0; j < neighbours_num; j += PILOT_BLOCK_SIZE_X)
        {
            float distance = current_nns[j];

            if(distance < threshold)
            {
                counters[local_id_y][local_id_x]++;
            }
        }

        barrier(CLK_LOCAL_MEM_FENCE);

        /** reduction */

        for (unsigned int s = PILOT_BLOCK_SIZE_X; s > 0; s >>= 1)
        {
            if (local_id_x < s)
            {
                counters[local_id_y][local_id_x]
                                       += counters[local_id_y][local_id_x + s];
            }

            barrier(CLK_LOCAL_MEM_FENCE);
        }

        /** writing result */
        if(local_id_x == 0)
        {
            result[nns_base_group + i] = counters[local_id_y][0];
        }
    }
}

__kernel void bindPilotsKernel(__global const unint* indexes,
                               __global const real* repsPilots,
                               __global real* pilots,
                               unint pilots_size)
{

    int x = get_global_id(0);

    if(x < pilots_size)
    {
        pilots[x] = repsPilots[indexes[x]];
    }
}


__kernel void meanshiftPlanKNNKernel(__global const real* Q_mat,
                            unint Q_r,
                            unint Q_c,
                            unint Q_pr,
                            unint Q_pc,
                            unint Q_ld,
                            __global const unint* qMap,
                            __global const real* X_mat,
                            unint X_r,
                            unint X_c,
                            unint X_pr,
                            unint X_pc,
                            unint X_ld,
                            __global const unint* xMap_mat,
                            unint xMap_r,
                            unint xMap_c,
                            unint xMap_pr,
                            unint xMap_pc,
                            unint xMap_ld,
//                            __global real* dMins_mat,
//                            unint dMins_r,
//                            unint dMins_c,
//                            unint dMins_pr,
//                            unint dMins_pc,
//                            unint dMins_ld,
//                            __global unint* dMinIDs_mat,
//                            unint dMinIDs_r,
//                            unint dMinIDs_c,
//                            unint dMinIDs_pr,
//                            unint dMinIDs_pc,
//                            unint dMinIDs_ld,
                            __global const unint* cP_numGroups,
                            __global const unint* cP_groupCountX,
                            __global const unint* cP_qToQGroup,
                            __global const unint* cP_qGroupToXGroup,
                            unint cP_ld,
                            unint qStartPos,
                            __global const real* windows,
                            __global real* selectedPoints,
                            __global unint* selectedPointsNums,
                            __global real* newWindows,
                            unint maxPointsNum)
{

    size_t threadIdx_x = get_local_id(0);
    size_t threadIdx_y = get_local_id(1);

    size_t blockIdx_x = get_group_id(0);
    size_t blockIdx_y = get_group_id(1);

    unint qB = qStartPos + blockIdx_y * BLOCK_SIZE;  //indexes Q
    unint xB; //X (DB) Block;
    unint cB; //column Block
    unint offQ = threadIdx_y; //the offset of qPos in this block
    unint offX = threadIdx_x; //ditto for x

//    __local real dNN[BLOCK_SIZE][KMAX + BLOCK_SIZE];
//    __local unint idNN[BLOCK_SIZE][KMAX + BLOCK_SIZE];

    __local unint valid_indices[BLOCK_SIZE][BLOCK_SIZE];
    volatile __local unint local_count[BLOCK_SIZE];
    volatile __local unint global_count[BLOCK_SIZE];
    volatile __local real min_windows[BLOCK_SIZE][BLOCK_SIZE];

    __local real Xs[BLOCK_SIZE][BLOCK_SIZE];
    __local real Qs[BLOCK_SIZE][BLOCK_SIZE];

    unint g = cP_qToQGroup[qB]; /** query group of q */
    //unint numGroups = cP_numGroups[g]; /** always 1 in case of identity matrix */

    //valid_indices[offQ][offX] = 0;

    if(offQ == 0)
    {
     //   local_count[offX] = 0;
        global_count[offX] = 0;
    }

//    dNN[offQ][offX] = FLT_MAX;//MAX_REAL;
//    dNN[offQ][offX + 16] = FLT_MAX;//MAX_REAL;
//    idNN[offQ][offX] = DUMMY_IDX;
//    idNN[offQ][offX + 16] = DUMMY_IDX;

    barrier(CLK_LOCAL_MEM_FENCE);


    int i = 1; /** assumption: we have only one group to visit */

    //DB group currently being examined
    unint xG = cP_qGroupToXGroup[IDX(g, i, cP_ld)];
    unint groupCount = cP_groupCountX[IDX(g, i, cP_ld)];

    unint groupIts = (groupCount + BLOCK_SIZE - 1) / BLOCK_SIZE;

    unint queryPointIdx = qMap[qB + offQ];

    for(unint j = 0; j < groupIts; j++) //iterate over elements of group
    {
        xB = j * BLOCK_SIZE;
        real ans = 0.f;

        unint databasePointIdx = xMap_mat[IDX(xG, xB + offQ, xMap_ld)];
        min_windows[offQ][offX] = FLT_MAX;

        local_count[offX] = 0; /** reset locac counts */

        /** iterate over cols to compute distances */
        for(cB = 0; cB < X_pc; cB += BLOCK_SIZE)
        {
            unint databaseElemIdx = IDX(databasePointIdx, cB + offX, X_ld);

            unint queryElemIdx = IDX(queryPointIdx, cB + offX, Q_ld);

            /** database points */
            Xs[offX][offQ] = X_mat[databaseElemIdx];

            /** query points */
            Qs[offX][offQ] = ((queryPointIdx == DUMMY_IDX)
                                                    ? 0 : Q_mat[queryElemIdx]);
            barrier(CLK_LOCAL_MEM_FENCE);

            /** calculating partial distance */
            for(unint k = 0; k < BLOCK_SIZE; k++)
                ans += DIST(Xs[k][offX], Qs[k][offQ]);

            barrier(CLK_LOCAL_MEM_FENCE);
        }

        /** at this point, distance is complete (ans) */

        /** load window */
        real window = windows[databasePointIdx];

        bool isOk = (xB + offX < groupCount) && (ans < window);

        if(isOk)
        {
            int idx = atomic_inc(local_count + offQ);
            valid_indices[offQ][idx] = databasePointIdx;
            min_windows[offQ][offX] = min(min_windows[offQ][offX], window);
        }

        barrier(CLK_LOCAL_MEM_FENCE);

        /** write indexes to global memory */

        if(offX < local_count[offQ] && queryPointIdx != DUMMY_IDX)
        {
            int baseIdx = queryPointIdx * maxPointsNum;
            int colIdx = global_count[offQ] + offX;

            if(colIdx < maxPointsNum)
                selectedPoints[baseIdx + colIdx] = valid_indices[offQ][offX];
        }

        if(offX == 0 && queryPointIdx != DUMMY_IDX)
        {
            real total_min = FLT_MAX;

            for(uint i = 0; i < BLOCK_SIZE; ++i) /** finally it should be done via reduction */
            {
                total_min = min(total_min, min_windows[offQ][i]);
            }
            newWindows[queryPointIdx] = total_min;
        }

        barrier(CLK_LOCAL_MEM_FENCE);

        /** add local sums to global indexes */
        if(offX == 0)
        {
            global_count[offQ] += local_count[offQ];

        }

        barrier(CLK_LOCAL_MEM_FENCE);
    }

    /** writing total numbers of elements which satisfy given condition */
    if(offX == 0 && queryPointIdx != DUMMY_IDX)
    {
        selectedPointsNums[queryPointIdx] = min(global_count[offQ],
                                                       maxPointsNum);
    }
   // else if(offQ == 0)
  // {
   //     selectedPointsNums[queryPointIdx + offX] = 0;
   // }



//    if(qMap[qB + offQ] != DUMMY_IDX)
//    {
//        int out_idx = IDX(qMap[qB + offQ], offX, dMins_ld);

//        dMins_mat[out_idx] = dNN[offQ][offX];
//        dMins_mat[out_idx + 16] = dNN[offQ][offX + 16];

//        out_idx = IDX(qMap[qB + offQ], offX, dMinIDs_ld);

//        dMinIDs_mat[out_idx] = idNN[offQ][offX];
//        dMinIDs_mat[out_idx + 16] = idNN[offQ][offX + 16];

//    }
}


__kernel void meanshiftMeanKernel(__global const real* X_mat,
                                  unint X_r,
                                  unint X_c,
                                  unint X_pr,
                                  unint X_pc,
                                  unint X_ld,
                                  __global real* Y_mat,
                                  unint Y_r,
                                  unint Y_c,
                                  unint Y_pr,
                                  unint Y_pc,
                                  unint Y_ld,
                                  __global const unint* selectedPoints,
                                  __global const unint* selectedPointsNums,
                                  unint maxPointsNum)
{
    size_t local_id_x = get_local_id(0);
    size_t local_id_y = get_local_id(1);

    size_t global_id_x = get_global_id(0);
    size_t global_id_y = get_global_id(1);

    size_t block_id_x = get_group_id(0);
    size_t block_id_y = get_group_id(1);

    __local real localMean[BLOCK_SIZE][BLOCK_SIZE];

    int numPoints = selectedPoints[global_id_y];

    for(unint j = local_id_x; j < X_c; j += BLOCK_SIZE)
    {
        localMean[local_id_y][local_id_x] = 0;

        for(unint i = 0; i < numPoints; ++i)
        {
            int idx = selectedPoints[maxPointsNum * global_id_y + i];

      //      localMean[local_id_y][local_id_x] += 5;//X_mat[IDX(idx, j, X_ld)];
        }

//        Y_mat[IDX(global_id_y, j, Y_ld)] = localMean[local_id_y][local_id_x]
//                                                                   / numPoints;
    }
}

