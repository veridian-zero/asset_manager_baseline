FROM ubuntu:22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    git \
    ca-certificates \
    libgl1-mesa-dev \
    libglu1-mesa-dev \
    libgl1-mesa-glx \
    libglu1-mesa \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/build

RUN git clone --depth 1 --branch OpenSceneGraph-3.6 https://github.com/openscenegraph/OpenSceneGraph.git

RUN cmake -S OpenSceneGraph -B build_dir \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/opt/osg \
    -DBUILD_OSG_APPLICATIONS=ON \
    -DBUILD_OSG_EXAMPLES=OFF \
    -D_OPENTHREADS_ATOMIC_USE_GCC_BUILTINS=ON

RUN cmake --build build_dir --target install -j$(nproc)

RUN rm -rf /opt/build

WORKDIR /data

ENV PATH=/opt/osg/bin:$PATH
ENV LD_LIBRARY_PATH=/opt/osg/lib:/opt/osg/lib64:$LD_LIBRARY_PATH

RUN ldconfig

ENTRYPOINT ["osgconv"]

