#include <iostream>
#include <string>
#include <algorithm>
#include <cmath>
#include <filesystem>
#include <vector>

#include <osgDB/ReadFile>
#include <osgDB/WriteFile>
#include <osgDB/Registry>
#include <osgViewer/Viewer>
#include <osg/Camera>
#include <osg/Image>
#include <osg/ComputeBoundsVisitor>
#include <osg/RenderInfo>
#include <osg/LightSource>
#include <osg/Light>
#include <osg/StateSet>
#include <osg/Group>

struct SnapImageCallback : public osg::Camera::DrawCallback {
    osg::ref_ptr<osg::Image> _image;
    SnapImageCallback(osg::Image* image) : _image(image) {}

    virtual void operator()(osg::RenderInfo& renderInfo) const override {
        osg::Camera* camera = renderInfo.getCurrentCamera();
        if (!camera || !camera->getViewport()) return;

        osg::Viewport* vp = camera->getViewport();
        _image->setPacking(1);
        _image->readPixels(vp->x(), vp->y(), vp->width(), vp->height(), GL_RGBA, GL_UNSIGNED_BYTE);
    }
};

osg::Vec4 parseBackgroundColor(const std::string& inputColor) {
    std::string colorStr = inputColor;
    std::transform(colorStr.begin(), colorStr.end(), colorStr.begin(), ::tolower);

    if (colorStr == "white")       return osg::Vec4(1.0f, 1.0f, 1.0f, 1.0f);
    if (colorStr == "slate")       return osg::Vec4(0.15f, 0.15f, 0.18f, 1.0f);
    if (colorStr == "dark")        return osg::Vec4(0.08f, 0.08f, 0.10f, 1.0f);
    if (colorStr == "light")       return osg::Vec4(0.85f, 0.85f, 0.88f, 1.0f);
    if (colorStr == "green" || colorStr == "chroma") return osg::Vec4(0.0f, 1.0f, 0.0f, 1.0f);
    if (colorStr == "transparent") return osg::Vec4(0.0f, 0.0f, 0.0f, 0.0f);

    if (!colorStr.empty() && colorStr[0] == '#') {
        colorStr = colorStr.substr(1);
    }

    if (colorStr.length() == 6) {
        float r = std::stoi(colorStr.substr(0, 2), nullptr, 16) / 255.0f;
        float g = std::stoi(colorStr.substr(2, 2), nullptr, 16) / 255.0f;
        float b = std::stoi(colorStr.substr(4, 2), nullptr, 16) / 255.0f;
        return osg::Vec4(r, g, b, 1.0f);
    }

    return osg::Vec4(1.0f, 1.0f, 1.0f, 1.0f);
}

struct ViewTarget {
    std::string tag;
    std::string outputPath;
    osg::Vec3 eyeOffset;
    osg::Vec3 upVector;
};

int main(int argc, char** argv) {
    std::setvbuf(stdout, NULL, _IONBF, 0);
    std::setvbuf(stderr, NULL, _IONBF, 0);

    if (argc < 3) {
        std::cerr << "Usage: osgthumb <input_model.flt> <output_path_or_prefix> [view_angle: front|rear|left|right|top|all] [bg_color: white|slate|dark|light|green|transparent|#HEX]\n";
        return 1;
    }

    std::string inputFile   = argv[1];
    std::string outArg      = argv[2];
    std::string viewAngle   = (argc >= 4) ? argv[3] : "front";
    std::string bgColorArg  = (argc >= 5) ? argv[4] : "white";

    std::transform(viewAngle.begin(), viewAngle.end(), viewAngle.begin(), ::tolower);

    osgDB::Registry::instance()->getDataFilePathList().push_back("/data");

    osg::ref_ptr<osg::Node> model = osgDB::readNodeFile(inputFile);
    if (!model) {
        std::cerr << "ERROR: Failed to load model file: " << inputFile << std::endl;
        return 1;
    }

    model->getOrCreateStateSet()->setMode(GL_NORMALIZE, osg::StateAttribute::ON);

    osgViewer::Viewer viewer;
    viewer.setUpViewInWindow(0, 0, 1024, 768);

    osg::Camera* camera = viewer.getCamera();
    camera->setClearColor(parseBackgroundColor(bgColorArg));
    camera->setViewport(0, 0, 1024, 768);
    camera->setDrawBuffer(GL_BACK);
    camera->setReadBuffer(GL_BACK);
    camera->setRenderTargetImplementation(osg::Camera::FRAME_BUFFER);

    // Compute exact Bounding Box
    osg::ComputeBoundsVisitor cbv;
    model->accept(cbv);
    osg::BoundingBox bb = cbv.getBoundingBox();

    if (!bb.valid()) {
        std::cerr << "ERROR: Invalid model bounding box." << std::endl;
        return 1;
    }

    osg::Vec3 center = bb.center();
    float dx = bb.xMax() - bb.xMin();
    float dy = bb.yMax() - bb.yMin();
    float dz = bb.zMax() - bb.zMin();
    float maxHoriz = std::max(dx, dy);

    float effectiveZ = dz;
    if (dz > maxHoriz * 0.40f && maxHoriz < 30.0f) {
        effectiveZ = maxHoriz * 0.25f;
    }

    float fovYDeg = 20.0f;
    float aspect  = 1024.0f / 768.0f;
    float fovYRad = osg::DegreesToRadians(fovYDeg);
    float fovXRad = 2.0f * std::atan(std::tan(fovYRad * 0.5f) * aspect);
    float targetFillRatio = 0.85f;

    float distVertical   = (effectiveZ * 0.5f) / std::tan(fovYRad * 0.5f);
    float distHorizontal = (maxHoriz * 0.5f) / std::tan(fovXRad * 0.5f);
    float baseDist = std::max(distVertical, distHorizontal) / targetFillRatio;

    if (maxHoriz > 40.0f) {
        float diagDim = std::sqrt(dx * dx + dy * dy + dz * dz);
        float diagDistY = (diagDim * 0.5f) / std::tan(fovYRad * 0.5f);
        float diagDistX = (diagDim * 0.5f) / std::tan(fovXRad * 0.5f);
        baseDist = std::max(diagDistX, diagDistY) / 0.88f;
    }

    float topDistY = (dy * 0.5f) / std::tan(fovYRad * 0.5f);
    float topDistX = (dx * 0.5f) / std::tan(fovXRad * 0.5f);
    float topDist  = std::max(topDistX, topDistY) / targetFillRatio;

    std::vector<ViewTarget> targetsToRender;

    if (viewAngle == "all") {
        // Output argument is used as a file prefix, e.g. /data/ExportDir/ModelName
        targetsToRender.push_back({ "front", outArg + "_front.png", osg::Vec3(baseDist * 0.6f, baseDist * 0.7f, baseDist * 0.40f), osg::Vec3(0.0f, 0.0f, 1.0f) });
        targetsToRender.push_back({ "rear",  outArg + "_rear.png",  osg::Vec3(-baseDist * 0.6f, -baseDist * 0.7f, baseDist * 0.40f), osg::Vec3(0.0f, 0.0f, 1.0f) });
        targetsToRender.push_back({ "left",  outArg + "_left.png",  osg::Vec3(-baseDist * 1.0f, 0.0f, baseDist * 0.05f), osg::Vec3(0.0f, 0.0f, 1.0f) });
        targetsToRender.push_back({ "right", outArg + "_right.png", osg::Vec3(baseDist * 1.0f, 0.0f, baseDist * 0.05f), osg::Vec3(0.0f, 0.0f, 1.0f) });
        targetsToRender.push_back({ "top",   outArg + "_top.png",   osg::Vec3(0.0f, 0.001f, topDist), osg::Vec3(0.0f, 1.0f, 0.0f) });
    } else {
        // Single angle mode: output argument is exact target file path
        osg::Vec3 offset, up(0.0f, 0.0f, 1.0f);
        if (viewAngle == "rear") {
            offset = osg::Vec3(-baseDist * 0.6f, -baseDist * 0.7f, baseDist * 0.40f);
        } else if (viewAngle == "left" || viewAngle == "left_side") {
            offset = osg::Vec3(-baseDist * 1.0f, 0.0f, baseDist * 0.05f);
        } else if (viewAngle == "right" || viewAngle == "right_side") {
            offset = osg::Vec3(baseDist * 1.0f, 0.0f, baseDist * 0.05f);
        } else if (viewAngle == "top") {
            offset = osg::Vec3(0.0f, 0.001f, topDist);
            up = osg::Vec3(0.0f, 1.0f, 0.0f);
        } else { // default front
            offset = osg::Vec3(baseDist * 0.6f, baseDist * 0.7f, baseDist * 0.40f);
        }
        targetsToRender.push_back({ viewAngle, outArg, offset, up });
    }

    for (const auto& target : targetsToRender) {
        osg::Vec3 eye = center + target.eyeOffset;
        camera->setViewMatrixAsLookAt(eye, center, target.upVector);
        camera->setProjectionMatrixAsPerspective(fovYDeg, aspect, 0.1f, baseDist * 10.0f);

        // Dynamic light placed at camera position
        osg::ref_ptr<osg::Light> studioLight = new osg::Light;
        studioLight->setLightNum(0);
        studioLight->setAmbient(osg::Vec4(0.45f, 0.45f, 0.45f, 1.0f));
        studioLight->setDiffuse(osg::Vec4(0.85f, 0.85f, 0.85f, 1.0f));
        studioLight->setSpecular(osg::Vec4(0.15f, 0.15f, 0.15f, 1.0f));

        osg::Vec3 lightPos = eye + osg::Vec3(baseDist * 0.2f, 0.0f, baseDist * 0.3f);
        studioLight->setPosition(osg::Vec4(lightPos.x(), lightPos.y(), lightPos.z(), 1.0f));

        osg::ref_ptr<osg::LightSource> lightSource = new osg::LightSource;
        lightSource->setLight(studioLight.get());

        osg::ref_ptr<osg::Group> root = new osg::Group;
        root->addChild(lightSource.get());
        root->addChild(model.get());
        root->getOrCreateStateSet()->setMode(GL_LIGHT0, osg::StateAttribute::ON);
        root->getOrCreateStateSet()->setMode(GL_LIGHTING, osg::StateAttribute::ON);

        osg::ref_ptr<osg::Image> image = new osg::Image;
        camera->setFinalDrawCallback(new SnapImageCallback(image.get()));

        viewer.setSceneData(root.get());
        viewer.realize();
        viewer.frame();
        viewer.frame();

        std::filesystem::path outPath(target.outputPath);
        if (outPath.has_parent_path()) {
            std::filesystem::create_directories(outPath.parent_path());
        }

        if (image->valid() && osgDB::writeImageFile(*image, target.outputPath)) {
            std::cout << "SUCCESS: Rendered [" << target.tag << "] view to " << target.outputPath << std::endl;
        } else {
            std::cerr << "ERROR: Failed to save image to " << target.outputPath << std::endl;
        }
    }

    return 0;
}