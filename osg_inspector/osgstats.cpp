#include <iostream>
#include <string>
#include <algorithm>
#include <vector>
#include <set>

#include <osgDB/ReadFile>
#include <osgDB/Registry>
#include <osg/NodeVisitor>
#include <osg/LOD>
#include <osg/PagedLOD>
#include <osg/MatrixTransform>
#include <osg/PositionAttitudeTransform>
#include <osg/Sequence>
#include <osg/Switch>
#include <osg/Geode>
#include <osg/Geometry>
#include <osg/Texture2D>
#include <osg/ComputeBoundsVisitor>
#include <osgSim/DegreeOfFreedom>
#include <osgSim/MultiSwitch>

class FastInspectorVisitor : public osg::NodeVisitor {
public:
    int totalPolygons = 0;
    int lodCount = 0;
    int articulationCount = 0;
    int damageStateCount = 0;
    int appearanceCount = 0;

    std::vector<std::string> lodRanges;
    std::vector<std::string> articulations;
    std::vector<std::string> damageStates;
    std::vector<std::string> appearances;
    std::set<std::string> texturesFound;
    std::vector<std::string> packageList;

    int maxTexResX = 0;
    int maxTexResY = 0;

    FastInspectorVisitor() : osg::NodeVisitor(osg::NodeVisitor::TRAVERSE_ALL_CHILDREN) {}

    virtual void apply(osg::Node& node) override {
        // Inspect StateSet for Textures
        osg::StateSet* ss = node.getStateSet();
        if (ss) { checkStateSet(ss); }

        traverse(node);
    }

    virtual void apply(osg::LOD& lod) override {
        lodCount++;
        for (unsigned int i = 0; i < lod.getNumRanges(); ++i) {
            float minR = lod.getMinRange(i);
            float maxR = lod.getMaxRange(i);
            lodRanges.push_back(std::to_string((int)minR) + "-" + std::to_string((int)maxR) + "m");
        }
        traverse(lod);
    }

    virtual void apply(osg::Geode& geode) override {
        osg::StateSet* ss = geode.getStateSet();
        if (ss) { checkStateSet(ss); }

        for (unsigned int i = 0; i < geode.getNumDrawables(); ++i) {
            osg::Drawable* drawable = geode.getDrawable(i);
            if (drawable) {
                osg::StateSet* dss = drawable->getStateSet();
                if (dss) { checkStateSet(dss); }

                osg::Geometry* geom = drawable->asGeometry();
                if (geom) {
                    for (unsigned int p = 0; p < geom->getNumPrimitiveSets(); ++p) {
                        osg::PrimitiveSet* ps = geom->getPrimitiveSet(p);
                        if (ps) {
                            totalPolygons += ps->getNumPrimitives();
                        }
                    }
                }
            }
        }
        traverse(geode);
    }

    virtual void apply(osg::Transform& transform) override {
        osgSim::DegreeOfFreedom* dof = dynamic_cast<osgSim::DegreeOfFreedom*>(&transform);
        if (dof) {
            articulationCount++;
            articulations.push_back("DOF: " + dof->getName());
        }
        traverse(transform);
    }

    virtual void apply(osg::Switch& sw) override {
        osgSim::MultiSwitch* ms = dynamic_cast<osgSim::MultiSwitch*>(&sw);
        if (ms) {
            std::string name = ms->getName();
            std::transform(name.begin(), name.end(), name.begin(), ::tolower);
            if (name.find("damage") != std::string::npos) {
                damageStateCount++;
                damageStates.push_back(ms->getName());
            } else {
                appearanceCount++;
                appearances.push_back(ms->getName());
            }
        }
        traverse(sw);
    }

private:
    void checkStateSet(osg::StateSet* ss) {
        for (unsigned int unit = 0; unit < ss->getNumTextureAttributeLists(); ++unit) {
            osg::Texture2D* tex = dynamic_cast<osg::Texture2D*>(ss->getTextureAttribute(unit, osg::StateAttribute::TEXTURE));
            if (tex && tex->getImage()) {
                osg::Image* img = tex->getImage();
                if (!img->getFileName().empty()) {
                    texturesFound.insert(img->getFileName());
                    packageList.push_back(img->getFileName());
                }
                if (img->s() > maxTexResX) maxTexResX = img->s();
                if (img->t() > maxTexResY) maxTexResY = img->t();
            }
        }
    }
};

int main(int argc, char** argv) {
    std::setvbuf(stdout, NULL, _IONBF, 0);
    std::setvbuf(stderr, NULL, _IONBF, 0);

    if (argc < 2) {
        std::cerr << "Usage: osg-inspector <input_model.flt>\n";
        return 1;
    }

    std::string inputFile = argv[1];
    osgDB::Registry::instance()->getDataFilePathList().push_back("/data");

    // Load OpenFlight node tree without loading unnecessary plugin options
    osg::ref_ptr<osg::Node> model = osgDB::readNodeFile(inputFile);
    if (!model) {
        std::cerr << "ERROR: Failed to load model file: " << inputFile << std::endl;
        return 1;
    }

    // Fast Traversal
    FastInspectorVisitor visitor;
    model->accept(visitor);

    // Fast Bounding Box calculation
    osg::ComputeBoundsVisitor cbv;
    model->accept(cbv);
    osg::BoundingBox bb = cbv.getBoundingBox();

    // Output formatted key-value pairs for PowerShell parser
    std::cout << "LODCount=" << visitor.lodCount << "\n";
    std::cout << "PolygonCount=" << visitor.totalPolygons << "\n";
    if (!visitor.lodRanges.empty()) {
        std::cout << "Range=" << visitor.lodRanges[0] << "\n";
    }
    std::cout << "ArticulationCount=" << visitor.articulationCount << "\n";
    for (const auto& art : visitor.articulations) {
        std::cout << "Description=" << art << "\n";
        std::cout << "Details=Articulated DOF Node\n";
    }
    std::cout << "DamageStateCount=" << visitor.damageStateCount << "\n";
    for (const auto& dmg : visitor.damageStates) {
        std::cout << "DamageStateName=" << dmg << "\n";
    }
    std::cout << "AppearanceCount=" << visitor.appearanceCount << "\n";
    for (const auto& app : visitor.appearances) {
        std::cout << "Description=" << app << "\n";
        std::cout << "States=Switch State\n";
    }

    if (visitor.maxTexResX > 0 && visitor.maxTexResY > 0) {
        std::cout << "TextureResolutionX=" << visitor.maxTexResX << "\n";
        std::cout << "TextureResolutionY=" << visitor.maxTexResY << "\n";
    }

    if (bb.valid()) {
        std::cout << "BoundingBox=X:[" << bb.xMin() << " to " << bb.xMax() 
                  << "] Y:[" << bb.yMin() << " to " << bb.yMax() 
                  << "] Z:[" << bb.zMin() << " to " << bb.zMax() << "]\n";
    }

    if (!visitor.packageList.empty()) {
        std::cout << "PackageList=";
        for (size_t i = 0; i < visitor.packageList.size(); ++i) {
            std::cout << visitor.packageList[i] << (i + 1 < visitor.packageList.size() ? "|" : "");
        }
        std::cout << "\n";
    }

    return 0;
}