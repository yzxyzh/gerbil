/*
	Copyright(c) 2012 Johannes Jordan <johannes.jordan@cs.fau.de>.
	Copyright(c) 2012 Petr Koupy <petr.koupy@gmail.com>

	This file may be licensed under the terms of of the GNU General Public
	License, version 3, as published by the Free Software Foundation. You can
	find it here: http://www.gnu.org/licenses/gpl.html
*/

#ifndef MAINWINDOW_H
#define MAINWINDOW_H

#include "ui_mainwindow.h"
#include "docks/roidock.h"
#include <shared_data.h>
#include <multi_img.h>
#include <labeling.h>
// TODO: should belong to a controller
#include <model/illumination.h>
#include <progress_observer.h>
#include "commandrunner.h"
#ifdef WITH_SEG_MEANSHIFT
#include <meanshift_shell.h>
#endif
#ifdef WITH_SEG_MEDIANSHIFT
#include <medianshift_shell.h>
#endif
#ifdef WITH_SEG_PROBSHIFT
#include <probshift_shell.h>
#endif
#include <graphseg.h>

#include <vector>
#include <QPixmap>
#include <QImage>
#include <QVector>
#include <QMenu>
#include <opencv2/core/core.hpp>

class IllumDock;
class RgbDock;
//TODO create
//class LabelDock;
class UsSegmentationDock;
class Controller;

class MainWindow : public QMainWindow, private Ui::MainWindow {
    Q_OBJECT
public:
	MainWindow(bool limitedMode = false);
	void initUI(size_t size);
	void initSignals(Controller *chief);

	// TODO: used by Controller; hack until we have a resp. vc-controller
	ViewerContainer* getViewerContainer() { return viewerContainer; }

	// setGUIEnabled() slot is now in Controller class
	void setGUIEnabled(bool enable, TaskType tt = TT_NONE);
public slots:
	void setCurrentLabel(int cl) { currentLabel = cl;}

	void addToLabel();
	void remFromLabel();

	// TODO -> segmentationDock
//	void segmentationFinished();
//	void segmentationApply(std::map<std::string, boost::any>);

	void bandsSliderMoved(int b);

	// TODO -> NormDock
	void normTargetChanged(bool usecurrent = false);
	void normModeSelected(int mode, bool targetchange = false, bool usecurrent = false);
	void normModeFixed();
	void applyNormUserRange();
	void clampNormUserRange();

	void loadSeeds();

	void openContextMenu();

	void screenshot();

signals:
	void ignoreLabelsRequested(bool);
	void singleLabelRequested(bool);
	void specRescaleRequested(int bands);
	void clearLabelRequested(short index);
	void alterLabelRequested(short index, const cv::Mat1b &mask, bool negative);

	// will be part of banddock
	void alterLabelingRequested(const cv::Mat1s &labels, const cv::Mat1b &mask);
	void newLabelingRequested(const cv::Mat1s &labels);

	void rgbRequested();

	void seedingDone(bool yeah = false);

	void setGUIEnabledRequested(bool enable, TaskType tt);

	void graphSegDockVisibleRequested(bool visible);

protected:
	void changeEvent(QEvent *e);

private:
	void initNormalizationUI();


	QMenu *contextMenu;

	bool limitedMode;
	// the index of the label currently being edited
	int currentLabel;
};

#endif // MAINWINDOW_H
