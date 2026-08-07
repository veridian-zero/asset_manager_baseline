FROM ubuntu:22.04

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
    libpng-dev \
    libjpeg-dev \
    xvfb \
    xauth \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/build

RUN git clone --depth 1 --branch OpenSceneGraph-3.6 https://github.com/openscenegraph/OpenSceneGraph.git

RUN cmake -S OpenSceneGraph -B build_dir \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/opt/osg \
    -DBUILD_OSG_APPLICATIONS=OFF \
    -DBUILD_OSG_EXAMPLES=OFF \
    -D_OPENTHREADS_ATOMIC_USE_GCC_BUILTINS=ON

RUN cmake --build build_dir --target install -j$(nproc)

# Copy osgthumb.cpp and entrypoint script
COPY osgthumb.cpp /opt/build/osgthumb.cpp
COPY entrypoint.sh /opt/osg/bin/entrypoint.sh

# Convert line endings, set permissions, and compile osgthumb with -std=c++17
RUN sed -i 's/\r$//' /opt/osg/bin/entrypoint.sh && \
    chmod +x /opt/osg/bin/entrypoint.sh && \
    mkdir -p /opt/osg/bin && \
    g++ -O3 -std=c++17 /opt/build/osgthumb.cpp -o /opt/osg/bin/osgthumb \
    -I/opt/osg/include \
    -L/opt/osg/lib -L/opt/osg/lib64 \
    -Wl,-rpath,/opt/osg/lib:/opt/osg/lib64 \
    -losgViewer -losgDB -losgGA -losgUtil -losg -lOpenThreads -lGL

RUN rm -rf /opt/build

WORKDIR /data

ENV PATH=/opt/osg/bin:$PATH
ENV LD_LIBRARY_PATH=/opt/osg/lib:/opt/osg/lib64:$LD_LIBRARY_PATH

RUN ldconfig

# Use direct entrypoint script instead of xvfb-run wrapper
ENTRYPOINT ["/opt/osg/bin/entrypoint.sh"]