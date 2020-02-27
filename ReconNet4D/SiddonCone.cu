#include "Siddon.h"
#include "Projector.h"
#include "cudaMath.h"

#include <stdexcept>
#include <iostream>
#include <sstream>

using namespace std;

__device__ __host__ float3 GetDstForCone(float u, float v,
		const float3& detCenter, const float3& detU, const float3& detV, const Grid grid)
{
	return make_float3(detCenter.x + detU.x * u + detV.x * v,
		detCenter.y + detU.y * u + detV.y * v,
		detCenter.z + detU.z * u + detV.z * v);

}

__global__ void SiddonConeProjectionAbitraryKernel(float* pPrj, const float* pImg,
	const float3* pDetCenter, const float3* pDetU, const float3* pDetV, const float3* pSrc,
	int nview, int nc, const Detector det, const Grid grid)
{
	int iu = blockDim.x * blockIdx.x + threadIdx.x;
	int iview = blockDim.y * blockIdx.y + threadIdx.y;
	int iv = blockDim.z * blockIdx.z + threadIdx.z;

	if (iu >= det.nu || iv >= det.nv || iview >= nview)
	{
		return;
	}

	float u = (iu - det.off_u - (det.nu - 1) / 2.0f) * det.du;
	float v = (iv - det.off_v - (det.nv - 1) / 2.0f) * det.dv;

	float3 src = pSrc[iview];
	float3 dst = GetDstForCone(u, v, pDetCenter[iview], pDetU[iview], pDetV[iview], grid);
	MoveSourceDstNearGrid(src, dst, grid);

	SiddonRayTracing(pPrj + iu * nview * det.nv * nc + iview * det.nv * nc + iv * nc,
				pImg, src, dst, nc, grid);

}

__global__ void SiddonConeBackprojectionAbitraryKernel(float* pImg, const float* pPrj,
		const float3* pDetCenter, const float3* pDetU, const float3* pDetV, const float3* pSrc,
		int nview, int nc, const Detector det, const Grid grid)
{
	int iu = blockDim.x * blockIdx.x + threadIdx.x;
	int iview = blockDim.y * blockIdx.y + threadIdx.y;
	int iv = blockDim.z * blockIdx.z + threadIdx.z;

	if (iu >= det.nu || iv >= det.nv || iview >= nview)
	{
		return;
	}

	float u = (iu - det.off_u - (det.nu - 1) / 2.0f) * det.du;
	float v = (iv - det.off_v - (det.nv - 1) / 2.0f) * det.dv;

	float3 src = pSrc[iview];
	float3 dst = GetDstForCone(u, v, pDetCenter[iview], pDetU[iview], pDetV[iview], grid);
	MoveSourceDstNearGrid(src, dst, grid);

	SiddonRayTracingTransposeAtomicAdd(pImg, pPrj[iu * nview * det.nv * nc + iview * det.nv * nc + iv * nc],
			src, dst, nc, grid);

}

void SiddonCone::ProjectionAbitrary(const float* pcuImg, float* pcuPrj, const float* pcuDetCenter,
		const float* pcuDetU, const float* pcuDetV, const float* pcuSrc)
{
	dim3 threads, blocks;
	GetThreadsForXZ(threads, blocks, nu, nview, nv);

	for (int ib = 0; ib < nBatches; ib++)
	{
		for (int ic = 0; ic < nChannels; ic++)
		{
			SiddonConeProjectionAbitraryKernel<<<blocks, threads, 0, m_stream>>>(
					pcuPrj + ib * nu * nview * nv * nChannels + ic,
					pcuImg + ib * nx * ny * nz * nChannels + ic,
					(const float3*)pcuDetCenter, (const float3*)pcuDetU,
					(const float3*)pcuDetV, (const float3*)pcuSrc,
					nview, nChannels, MakeDetector(nu, nv, du, dv, off_u, off_v),
					MakeGrid(nx, ny, nz, dx, dy, dz, cx, cy, cz));

			cudaDeviceSynchronize();
		}
	}

}

void SiddonCone::BackprojectionAbitrary(float* pcuImg, const float* pcuPrj, const float* pcuDetCenter,
			const float* pcuDetU, const float* pcuDetV, const float* pcuSrc)
{
	dim3 threads, blocks;
	GetThreadsForXZ(threads, blocks, nu, nview, nv);

	for (int ib = 0; ib < nBatches; ib++)
	{
		for (int ic = 0; ic < nChannels; ic++)
		{
			SiddonConeBackprojectionAbitraryKernel<<<blocks, threads, 0, m_stream>>>(
					pcuImg + ib * nx * ny * nz * nChannels + ic,
					pcuPrj + ib * nu * nview * nv * nChannels + ic,
					(const float3*)pcuDetCenter, (const float3*)pcuDetU,
					(const float3*)pcuDetV, (const float3*)pcuSrc,
					nview, nChannels, MakeDetector(nu, nv, du, dv, off_u, off_v),
					MakeGrid(nx, ny, nz, dx, dy, dz, cx, cy, cz));

			cudaDeviceSynchronize();
		}
	}
}

extern "C" void cSiddonConeProjectionAbitrary(float* prj, const float* img,
		const float* detCenter, const float* detU, const float* detV, const float* src,
		int nBatches, int nChannels,
		int nx, int ny, int nz, float dx, float dy, float dz, float cx, float cy, float cz,
		int nu, int nview, int nv, float du, float dv, float off_u, float off_v)
{
	float* pcuPrj = NULL;
	float* pcuImg = NULL;
	float* pcuDetCenter = NULL;
	float* pcuDetU = NULL;
	float* pcuDetV = NULL;
	float* pcuSrc = NULL;

	try
	{
		if (cudaSuccess != cudaMalloc(&pcuPrj, sizeof(float) * nu * nv * nview * nBatches * nChannels))
		{
			throw ("pcuPrj allocation failed");
		}
		if (cudaSuccess != cudaMalloc(&pcuImg, sizeof(float) * nx * ny * nz * nBatches * nChannels))
		{
			throw ("pcuImg allocation failed");
		}
		if (cudaSuccess != cudaMalloc(&pcuDetCenter, sizeof(float3) * nview))
		{
			throw ("pcuDetCenter allocation failed");
		}
		if (cudaSuccess != cudaMalloc(&pcuDetU, sizeof(float3) * nview))
		{
			throw ("pcuDetU allocation failed");
		}
		if (cudaSuccess != cudaMalloc(&pcuDetV, sizeof(float3) * nview))
		{
			throw ("pcuDetV allocation failed");
		}
		if (cudaSuccess != cudaMalloc(&pcuSrc, sizeof(float3) * nview))
		{
			throw ("pcuSrc allocation failed");
		}
	}
	catch (exception& e)
	{
		if (pcuPrj != NULL) cudaFree(pcuPrj);
		if (pcuImg != NULL) cudaFree(pcuImg);
		if (pcuDetCenter != NULL) cudaFree(pcuDetCenter);
		if (pcuDetU != NULL) cudaFree(pcuDetU);
		if (pcuDetV != NULL) cudaFree(pcuDetV);
		if (pcuSrc != NULL) cudaFree(pcuSrc);

		ostringstream oss;
		oss << "cSiddonParallelProjection() failed: " << e.what()
				<< " (" << cudaGetErrorString(cudaGetLastError()) << ")";
		cerr << oss.str() << endl;
		throw(oss.str().c_str());
	}

	cudaMemcpy(pcuImg, img, sizeof(float) * nx * ny * nz * nBatches * nChannels, cudaMemcpyHostToDevice);
	cudaMemcpy(pcuDetCenter, detCenter, sizeof(float3) * nview, cudaMemcpyHostToDevice);
	cudaMemcpy(pcuDetU, detU, sizeof(float3) * nview, cudaMemcpyHostToDevice);
	cudaMemcpy(pcuDetV, detV, sizeof(float3) * nview, cudaMemcpyHostToDevice);
	cudaMemcpy(pcuSrc, src, sizeof(float3) * nview, cudaMemcpyHostToDevice);
	cudaMemset(pcuPrj, 0, sizeof(float) * nu * nview * nv * nBatches * nChannels);

	SiddonCone projector;
	projector.Setup(nBatches, nChannels, nx, ny, nz, dx, dy, dz, cx, cy, cz,
			nu, nview, nv, du, dv, off_u, off_v, 0, 0, 2);

	projector.ProjectionAbitrary(pcuImg, pcuPrj, pcuDetCenter, pcuDetU, pcuDetV, pcuSrc);
	cudaMemcpy(prj, pcuPrj, sizeof(float) * nu * nv * nview * nBatches * nChannels, cudaMemcpyDeviceToHost);

	cudaFree(pcuPrj);
	cudaFree(pcuImg);
	cudaFree(pcuDetCenter);
	cudaFree(pcuDetU);
	cudaFree(pcuDetV);
	cudaFree(pcuSrc);

}

extern "C" void cSiddonConeBackprojectionAbitrary(float* img, const float* prj,
		const float* detCenter, const float* detU, const float* detV, const float* src,
		int nBatches, int nChannels,
		int nx, int ny, int nz, float dx, float dy, float dz, float cx, float cy, float cz,
		int nu, int nview, int nv, float du, float dv, float off_u, float off_v)
{
	float* pcuPrj = NULL;
	float* pcuImg = NULL;
	float* pcuDetCenter = NULL;
	float* pcuDetU = NULL;
	float* pcuDetV = NULL;
	float* pcuSrc = NULL;

	try
	{
		if (cudaSuccess != cudaMalloc(&pcuPrj, sizeof(float) * nu * nv * nview * nBatches * nChannels))
		{
			throw ("pcuPrj allocation failed");
		}
		if (cudaSuccess != cudaMalloc(&pcuImg, sizeof(float) * nx * ny * nz * nBatches * nChannels))
		{
			throw ("pcuImg allocation failed");
		}
		if (cudaSuccess != cudaMalloc(&pcuDetCenter, sizeof(float3) * nview))
		{
			throw ("pcuDetCenter allocation failed");
		}
		if (cudaSuccess != cudaMalloc(&pcuDetU, sizeof(float3) * nview))
		{
			throw ("pcuDetU allocation failed");
		}
		if (cudaSuccess != cudaMalloc(&pcuDetV, sizeof(float3) * nview))
		{
			throw ("pcuDetV allocation failed");
		}
		if (cudaSuccess != cudaMalloc(&pcuSrc, sizeof(float3) * nview))
		{
			throw ("pcuSrc allocation failed");
		}
	}
	catch (exception& e)
	{
		if (pcuPrj != NULL) cudaFree(pcuPrj);
		if (pcuImg != NULL) cudaFree(pcuImg);
		if (pcuDetCenter != NULL) cudaFree(pcuDetCenter);
		if (pcuDetU != NULL) cudaFree(pcuDetU);
		if (pcuDetV != NULL) cudaFree(pcuDetV);
		if (pcuSrc != NULL) cudaFree(pcuSrc);

		ostringstream oss;
		oss << "cSiddonParallelProjection() failed: " << e.what()
				<< " (" << cudaGetErrorString(cudaGetLastError()) << ")";
		cerr << oss.str() << endl;
		throw(oss.str().c_str());
	}

	cudaMemcpy(pcuPrj, prj, sizeof(float) * nu * nv * nview * nBatches * nChannels, cudaMemcpyHostToDevice);
	cudaMemcpy(pcuDetCenter, detCenter, sizeof(float3) * nview, cudaMemcpyHostToDevice);
	cudaMemcpy(pcuDetU, detU, sizeof(float3) * nview, cudaMemcpyHostToDevice);
	cudaMemcpy(pcuDetV, detV, sizeof(float3) * nview, cudaMemcpyHostToDevice);
	cudaMemcpy(pcuSrc, src, sizeof(float3) * nview, cudaMemcpyHostToDevice);
	cudaMemset(pcuImg, 0, sizeof(float) * nx * ny * nz * nBatches * nChannels);

	SiddonCone projector;
	projector.Setup(nBatches, nChannels, nx, ny, nz, dx, dy, dz, cx, cy, cz,
			nu, nview, nv, du, dv, off_u, off_v, 0, 0, 2);

	projector.BackprojectionAbitrary(pcuImg, pcuPrj, pcuDetCenter, pcuDetU, pcuDetV, pcuSrc);

	cudaMemcpy(img, pcuImg, sizeof(float) * nx * ny * nz * nBatches * nChannels, cudaMemcpyDeviceToHost);



	cudaFree(pcuPrj);
	cudaFree(pcuImg);
	cudaFree(pcuDetCenter);
	cudaFree(pcuDetU);
	cudaFree(pcuDetV);
	cudaFree(pcuSrc);

}

