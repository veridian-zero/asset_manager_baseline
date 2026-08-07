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

# --- NEW: Build custom osgstats tool ---
COPY osgstats.cpp /opt/build/osgstats.cpp

RUN g++ -O3 /opt/build/osgstats.cpp -o /opt/osg/bin/osgstats \
    -I/opt/osg/include \
    -L/opt/osg/lib -L/opt/osg/lib64 \
    -Wl,-rpath,/opt/osg/lib:/opt/osg/lib64 \
    -losgDB -losgSim -losgUtil -losg -lOpenThreads

# --- Cleanup ---
RUN rm -rf /opt/build

WORKDIR /data

ENV PATH=/opt/osg/bin:$PATH
ENV LD_LIBRARY_PATH=/opt/osg/lib:/opt/osg/lib64:$LD_LIBRARY_PATH

RUN ldconfig

# Set default entrypoint to your new custom stats tool instead of osgconv
ENTRYPOINT ["osgstats"]
