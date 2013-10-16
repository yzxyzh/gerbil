#include "ocl_generic_som.h"

#include <CL/cl.hpp>
#include <iostream>
#include <string>
#include <sstream>

#include "stopwatch.h"

#include "ocl_utils.h"

extern const char* som_gpu_opt;

Ocl_GenericSOM::Ocl_GenericSOM(int som_width, int som_height, int som_depth,
               int neuron_size, const std::string& ocl_params)
    : d_data(som_width, som_height, som_depth, round_up_power2(neuron_size)),
      oclParams(ocl_params)//, neuron_size(neuron_size)
{
    local_distances = 0;

    initOpenCL();
    initParamters();
    initLocalMemDims();
    initRanges();
    initDeviceBuffers();
}

Ocl_GenericSOM::~Ocl_GenericSOM()
{
    if(local_distances)
        delete[] local_distances;
}

void Ocl_GenericSOM::uploadTrainingVectors()
{
    std::cout << "uploading training vectors!" << std::endl;

    int vectors_num = training_vectors.size();
    int buff_size = vectors_num * neuron_size_rounded;


    input_vectors = cl::Buffer(d_context, CL_MEM_READ_ONLY,
                              buff_size * sizeof(float));


    float* data = new float[buff_size];

    std::fill(data, data + buff_size, 0.f);

    for(int i = 0; i < vectors_num; ++i)
    {
        float* ptr = data + i * neuron_size_rounded;
        multi_img::Pixel& vec = training_vectors[i];

        std::copy(vec.begin(), vec.end(), ptr);
    }

    d_queue.enqueueWriteBuffer(input_vectors, CL_TRUE,
                               0, buff_size * sizeof(float),
                               data);

    delete[] data;

    std::cout << "uploading training vectors finished!" << std::endl;
}

void Ocl_GenericSOM::initOpenCL()
{
#ifdef OPENCL_PROFILE
    init_opencl(d_context, d_queue, true);
#else
    init_opencl(d_context, d_queue, false);
#endif

    std::string source(som_gpu_opt);

    cl::Device device = d_queue.getInfo<CL_QUEUE_DEVICE>();

    int device_type = device.getInfo<CL_DEVICE_TYPE>();

    preffered_group_size = 512;
    max_group_size = device.getInfo<CL_DEVICE_MAX_WORK_GROUP_SIZE>();

    neuron_size_rounded = d_data.neuron_size;

#ifdef DEBUG_MODE
    std::cout << "CL_DEVICE_MAX_WORK_GROUP_SIZE: "
              << CL_DEVICE_MAX_WORK_GROUP_SIZE << std::endl;
    std::cout << "CL_DEVICE_NAMEL: " << device.getInfo<CL_DEVICE_NAME>();
#endif

    std::stringstream stream;
    stream << "-DX_DIM=" << (neuron_size_rounded / 2);
    stream << " -DSOM_SIZE_X=" << d_data.x;
    stream << " -DSOM_SIZE_Y=" << d_data.y;
    stream << " -DSOM_SIZE_Z=" << d_data.z;

    if(device_type == CL_DEVICE_TYPE_CPU)
        stream << " -DCPU";

    stream << " " << oclParams;

#ifdef DEBUG_MODE
    stream << " -DDEBUG_MODE -Werror";
#endif

    program = build_cl_program(d_context, source, stream.str());

    // Make kernels
    calc_dist_kernel = cl::Kernel(program, "calculate_distances");
    local_min_kernel = cl::Kernel(program, "find_global_first_pass");
    global_min_kernel = cl::Kernel(program, "find_global_min");
    update_kernel = cl::Kernel(program, "update_network");
}

void Ocl_GenericSOM::initParamters()
{
    int width = d_data.x;
    int height = d_data.y;
    int depth = d_data.z;

    total_size = width * height * depth;
    total_size_rounded = round_up_power2(total_size);

    group_size = std::min(preffered_group_size, max_group_size);

    dist_find_local_x = neuron_size_rounded / 2;
    dist_find_local_y = group_size / dist_find_local_x;
    dist_find_local_z = 1;

    dist_find_global_x = dist_find_local_x * width;
    dist_find_global_y = round_up(height, dist_find_local_y);
    dist_find_global_z = depth;

    reduction_local = group_size;
    reduction_global = std::max(round_up_power2(total_size), reduction_local);

    assert(reduction_global % reduction_local == 0);

    reduced_elems_count = ((reduction_global + reduction_local - 1)
                          / reduction_local);

    update_radius = std::max(std::max(width - 1, height - 1), depth - 1);
}

void Ocl_GenericSOM::initLocalMemDims()
{
    dist_find_reduct_buff_local = cl::__local(sizeof(float)
                                   * dist_find_local_x
                                   * dist_find_local_y);

    reduct_buff_local = cl::__local(sizeof(float) * reduction_local);
}


void Ocl_GenericSOM::initRanges()
{
#ifdef DEBUG_MODE
    std::cout << "dist_find_local_x: " << dist_find_local_x << std::endl;
    std::cout << "dist_find_local_y: " << dist_find_local_y << std::endl;
    std::cout << "dist_find_local_z: " << dist_find_local_z << std::endl;

    std::cout << "dist_find_global_x: " << dist_find_global_x << std::endl;
    std::cout << "dist_find_global_y: " << dist_find_global_y << std::endl;
    std::cout << "dist_find_global_z: " << dist_find_global_z << std::endl;
#endif

    calc_dist_range_local = cl::NDRange(dist_find_local_x,
                                        dist_find_local_y,
                                        dist_find_local_z);

    calc_dist_range_global = cl::NDRange(dist_find_global_x,
                                         dist_find_global_y,
                                         dist_find_global_z);

    reduction_range_local = cl::NDRange(reduction_local);
    reduction_range_global = cl::NDRange(reduction_global);

//    update_global = cl::NDRange(kernel_global_x, kernel_global_y, dim);
//    update_local = cl::NDRange(kernel_size_x, kernel_size_y, dim);
}

void Ocl_GenericSOM::initDeviceBuffers()
{
    d_som = cl::Buffer(d_context, CL_MEM_READ_WRITE,
                       d_data.size * sizeof(float));

//    input_vector = cl::Buffer(d_context, CL_MEM_READ_ONLY,
//                              neuron_size_rounded * sizeof(float));

    distances = cl::Buffer(d_context, CL_MEM_READ_WRITE,
                               total_size * sizeof(float));

    //distances_host = new float[slice_size];

//    float* zero_vector = new float[neuron_size_rounded];
//    std::fill(zero_vector, zero_vector + neuron_size_rounded, 0.f);

//    d_queue.enqueueWriteBuffer(input_vector, CL_TRUE, 0,
//                               neuron_size_rounded * sizeof(float),
//                               zero_vector);
//    delete[] zero_vector;

    /* at least two uint values are needed to
     * store final winner x, y coordinates */
    out_min_indexes = cl::Buffer(d_context, CL_MEM_READ_WRITE,
                                 std::max(3, reduced_elems_count)
                                 * sizeof(int));

    out_min_values = cl::Buffer(d_context, CL_MEM_READ_WRITE,
                                reduced_elems_count * sizeof(float));

//    float f_max[] = {FLT_MAX, FLT_MAX};

//    d_queue.enqueueWriteBuffer(out_min_indexes, CL_TRUE, 0, sizeof(float) * 2,
//                               &f_max);
}

void Ocl_GenericSOM::setKernelParams()
{
    // Set arguments to kernel
    calc_dist_kernel.setArg(0, d_som);
    calc_dist_kernel.setArg(1, input_vectors);
    calc_dist_kernel.setArg(2, distances);
    //calculate_distances_kernel.setArg(3, 0);
    calc_dist_kernel.setArg(4, dist_find_reduct_buff_local);

    local_min_kernel.setArg(0, distances);
    local_min_kernel.setArg(1, out_min_values);
    local_min_kernel.setArg(2, out_min_indexes);
    local_min_kernel.setArg(3, reduct_buff_local);
    local_min_kernel.setArg(4, total_size);

    global_min_kernel.setArg(0, out_min_values);
    global_min_kernel.setArg(1, out_min_indexes);
//    global_min_kernel.setArg(2, width);

    update_kernel.setArg(0, d_som);
    update_kernel.setArg(1, input_vectors);
    update_kernel.setArg(2, out_min_indexes);
//    update_kernel.setArg(3, 0);
//    update_kernel.setArg(3, width);
//    update_kernel.setArg(4, height);
}


void Ocl_GenericSOM::clearSomData()
{
    std::fill(d_data.data, d_data.data + d_data.size, 0.f);
}

void Ocl_GenericSOM::uploadDataToDevice()
{
    d_queue.enqueueWriteBuffer(d_som, CL_TRUE, 0,
                               d_data.size * sizeof(float), d_data.data);
}

void Ocl_GenericSOM::downloadDataFromDevice()
{
    d_queue.enqueueReadBuffer(d_som, CL_TRUE, 0,
                              d_data.size * sizeof(float), d_data.data);
}


void Ocl_GenericSOM::train()
{
    setKernelParams();

#ifdef OPENCL_PROFILE
    initProfiling();
#endif

    try
    {
        for(int i = 0; i < training_vectors.size(); ++i)
        {
            updateRadius(i);

            if(update_radius == 0)
                break;

            findMinima(i);
            update(i);
        }
    }
    catch(cl::Error error)
    {
        std::cout << error.what()
                  << "(" << error.err() << ")" << std::endl;
    }

#ifdef OPENCL_PROFILE
    d_queue.finish();
    showProfilingInfo();
#endif

}

void Ocl_GenericSOM::findMinima(int vector_idx)
{
    calc_dist_kernel.setArg(3, vector_idx);

    cl::Event* event = 0;

#ifdef OPENCL_PROFILE
    event = &calc_dist_events[vector_idx];
#endif

    d_queue.enqueueNDRangeKernel(calc_dist_kernel,
                                 cl::NullRange,
                                 calc_dist_range_global,
                                 calc_dist_range_local, 0, event);

#ifdef OPENCL_PROFILE
    event = &local_min_events[vector_idx];
#endif

    d_queue.enqueueNDRangeKernel(local_min_kernel,
                                 cl::NullRange,
                                 reduction_range_global,
                                 reduction_range_local, 0, event);


    int second_reduct_local = std::min(max_group_size,
                                       preffered_group_size);
    int elems_to_reduce = reduced_elems_count;

    /* second step of reduction, only for very large soms there
     * will be more than one iteration performed*/
    do {

        if(elems_to_reduce < second_reduct_local)
        {
            second_reduct_local = round_up_power2(elems_to_reduce);
        }

        int second_reduct_global = round_up(elems_to_reduce,
                                   second_reduct_local);

        global_min_kernel.setArg(2, elems_to_reduce);

        global_min_kernel.setArg(3, cl::__local(sizeof(int)
                                                * second_reduct_local));

        cl::NDRange range_global(second_reduct_global);
        cl::NDRange range_local(second_reduct_local);

#ifdef OPENCL_PROFILE
        event = &global_min_events[vector_idx];
#endif
        d_queue.enqueueNDRangeKernel(global_min_kernel, cl::NullRange,
                                     range_global, range_local, 0, event);

        elems_to_reduce = ((second_reduct_global + second_reduct_local - 1)
                          / second_reduct_local);

    }while(elems_to_reduce > 1);

#ifdef DEBUG_MODE
    d_queue.enqueueReadBuffer(out_min_indexes, CL_TRUE, 0,
                              sizeof(int) * 3, &global_min);

    int winner_x = global_min[0];
    int winner_y = global_min[1];
    int winner_z = global_min[2];
#endif

}

void Ocl_GenericSOM::updateRadius(int vector_idx)
{
    double sigma = training_params[vector_idx].first;
    double learnRate = training_params[vector_idx].second;
    double sigmaSquare = sigma * sigma;

    while(update_radius > 0)
    {
        double dist = update_radius;

        double fakeGaussian = exp(-(dist) / (2.0 * sigmaSquare));
        double weight = learnRate * fakeGaussian;

        if(weight < 0.01)
            update_radius--;
        else
            break;
    }
}

void Ocl_GenericSOM::update(int vector_idx)
{
    int width = d_data.x;
    int height = d_data.y;
    int depth = d_data.z;

    double sigma = training_params[vector_idx].first;
    double learnRate = training_params[vector_idx].second;

    //cv::Point pos = neuron.get2dCoordinates();
    double sigmaSquare = sigma * sigma;

    int update_area_width = std::min(update_radius * 2 + 1, width);
    int update_area_height = std::min(update_radius * 2 + 1, height);
    int update_area_depth = std::min(update_radius * 2 + 1, depth);

    int local_x = neuron_size_rounded / 2;
    int local_y = std::min(group_size / local_x,
                           round_up_power2(update_radius * 2 + 1));

    int global_x = local_x * update_area_width;
    int global_y = round_up(update_area_height, local_y);

    cl::LocalSpaceArg update_weights_buff_local
            = cl::__local(sizeof(float) * local_y);

    update_kernel.setArg(3, vector_idx);
    update_kernel.setArg(4, update_radius);
    update_kernel.setArg(5, (float)sigmaSquare);
    update_kernel.setArg(6, (float)learnRate);
    update_kernel.setArg(7, update_weights_buff_local);

    cl::NDRange update_global(global_x, global_y, update_area_depth);
    cl::NDRange update_local(local_x, local_y, 1);

    cl::Event* event = 0;

#ifdef OPENCL_PROFILE
     event = &update_events[vector_idx];
#endif

    d_queue.enqueueNDRangeKernel(update_kernel, cl::NullRange,
                                 update_global, update_local, 0, event);
}

#ifdef OPENCL_PROFILE

void Ocl_GenericSOM::initProfiling()
{
    int iterations = training_vectors.size();

    calc_dist_events.clear();
    local_min_events.clear();
    global_min_events.clear();
    update_events.clear();

    calc_dist_events.resize(iterations);
    local_min_events.resize(iterations);
    global_min_events.resize(iterations);
    update_events.resize(iterations);
}

void Ocl_GenericSOM::showProfilingInfo()
{
    float total_time = 0.f;
    float kernel_time;
    int num_of_iterations;

    get_profile_info(calc_dist_events, kernel_time, num_of_iterations);
    total_time += kernel_time;

    std::cout << "calc_dist_kernel total time: "
              << kernel_time
              << " (" << num_of_iterations << " invocations)"
              << std::endl;

    get_profile_info(local_min_events, kernel_time, num_of_iterations);
    total_time += kernel_time;

    std::cout << "local_min_kernel total time: "
              << kernel_time
              << " (" << num_of_iterations << " invocations)"
              << std::endl;

    get_profile_info(global_min_events, kernel_time, num_of_iterations);
    total_time += kernel_time;

    std::cout << "global_min_kernel total time: "
              << kernel_time
              << " (" << num_of_iterations << " invocations)"
              << std::endl;

    get_profile_info(update_events, kernel_time, num_of_iterations);
    total_time += kernel_time;

    std::cout << "update_kernel total time: "
              << kernel_time
              << " (" << num_of_iterations << " invocations)"
              << std::endl;

    std::cout << "total time: " << total_time << std::endl;
}

#endif
