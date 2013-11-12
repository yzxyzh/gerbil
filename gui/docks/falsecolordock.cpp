#include <QVBoxLayout>
#include <QThread>

#include <iostream>
#include "gerbil_gui_debug.h"
#include "falsecolordock.h"
#include "../model/falsecolormodel.h"
#include "../widgets/scaledview.h"

std::ostream &operator<<(std::ostream& os, const FalseColoringState::Type& state)
{
	if (state < 0 || state >= 3) {
		os << "INVALID";
		return os;
	}
	const char * const str[] = { "FINISHED", "CALCULATING", "ABORTING"};
	os << str[state];
	return os;
}

static QStringList prettyFalseColorNames = QStringList()
		<< "True Color (CIE XYZ)"
		<< "Principle Component Analysis (PCA)"
		<< "Spectral-gradient PCA"
		<< "Self-organizing Map (SOM)"
		<< "Spectral-gradient SOM";

FalseColorDock::FalseColorDock(QWidget *parent)
	: QDockWidget(parent), lastShown(FalseColoring::CMF)
{
	setupUi(this);
	initUi();
}

void FalseColorDock::processColoringComputed(FalseColoring::Type coloringType, QPixmap p)
{
//	GGDBGM("enterState():"<<endl);
	enterState(coloringType, FalseColoringState::FINISHED);
	coloringUpToDate[coloringType] = true;
	updateTheButton();
	updateProgressBar();
	if (coloringType == selectedColoring()) {
		view->setEnabled(true);
		scene->setPixmap(p);
		view->update();
		view->setToolTip(prettyFalseColorNames[coloringType]);
		lastShown = coloringType;
	}
}

void FalseColorDock::processComputationCancelled(FalseColoring::Type coloringType)
{
	if(coloringState[coloringType] == FalseColoringState::ABORTING) {
		coloringProgress[coloringType] = 0;
//		GGDBGM("enterState():"<<endl);
		enterState(coloringType, FalseColoringState::FINISHED);
		updateTheButton();
		updateProgressBar();
	} else if(coloringState[coloringType] == FalseColoringState::CALCULATING) {
//		GGDBGM("restarting cancelled computation"<<endl);
		requestColoring(coloringType);
	}
}

void FalseColorDock::processSelectedColoring()
{
	//GGDBGM( "requesting false color image " << selectedColoring() << endl);
	requestColoring(selectedColoring());
	updateTheButton();
	updateProgressBar();
}

void FalseColorDock::processApplyClicked()
{
	if(coloringState[selectedColoring()] == FalseColoringState::CALCULATING) {
//		GGDBGM("enterState():"<<endl);
		enterState(selectedColoring(), FalseColoringState::ABORTING);
		emit cancelComputationRequested(selectedColoring());
		// go back to last shown coloring
		if(coloringUpToDate[lastShown]) {
			sourceBox->setCurrentIndex(int(lastShown));
			requestColoring(lastShown);
		} else { // or fall back to CMF, e.g. after ROI change
			sourceBox->setCurrentIndex(FalseColoring::CMF);
			requestColoring(FalseColoring::CMF);
		}
	} else if(coloringState[selectedColoring()] == FalseColoringState::FINISHED) {
		requestColoring(selectedColoring(), /* recalc */ true);
	}
}

void FalseColorDock::initUi()
{
	// initialize scaled view
	view->init();
	scene = new ScaledView();
	view->setScene(scene);

	// fill up source choices
	sourceBox->addItem(prettyFalseColorNames[FalseColoring::CMF],
					   FalseColoring::CMF);
	sourceBox->addItem(prettyFalseColorNames[FalseColoring::PCA],
					   FalseColoring::PCA);
	sourceBox->addItem(prettyFalseColorNames[FalseColoring::PCAGRAD],
					   FalseColoring::PCAGRAD);
#ifdef WITH_EDGE_DETECT
	sourceBox->addItem(prettyFalseColorNames[FalseColoring::SOM],
					   FalseColoring::SOM);
	sourceBox->addItem(prettyFalseColorNames[FalseColoring::SOMGRAD],
					   FalseColoring::SOMGRAD);
#endif // WITH_EDGE_DETECT
	sourceBox->setCurrentIndex(0);

	updateTheButton();
	updateProgressBar();

	connect(scene, SIGNAL(newSizeHint(QSize)),
			view, SLOT(updateSizeHint(QSize)));

	connect(sourceBox, SIGNAL(currentIndexChanged(int)),
			this, SLOT(processSelectedColoring()));

	connect(theButton, SIGNAL(clicked()),
			this, SLOT(processApplyClicked()));

	connect(this, SIGNAL(visibilityChanged(bool)),
			this, SLOT(processVisibilityChanged(bool)));
}

FalseColoring::Type FalseColorDock::selectedColoring()
{
	QVariant boxData = sourceBox->itemData(sourceBox->currentIndex());
	FalseColoring::Type coloringType = FalseColoring::Type(boxData.toInt());
	return coloringType;
}

void FalseColorDock::requestColoring(FalseColoring::Type coloringType, bool recalc)
{
//	GGDBGM("enterState():"<<endl);
	enterState(coloringType, FalseColoringState::CALCULATING);
	updateTheButton();
	emit falseColoringRequested(coloringType, recalc);
}

void FalseColorDock::updateProgressBar()
{
	if(coloringState[selectedColoring()] == FalseColoringState::CALCULATING) {
		int percent = coloringProgress[selectedColoring()];
		calcProgress->setVisible(true);
		calcProgress->setValue(percent);
	} else {
		calcProgress->setValue(0);
		calcProgress->setVisible(false);
	}
}

void FalseColorDock::updateTheButton()
{
	switch (coloringState[selectedColoring()]) {
	case FalseColoringState::FINISHED:
		theButton->setText("Re-Calculate");
		theButton->setVisible(false);
		if( selectedColoring()==FalseColoring::SOM ||
			selectedColoring()==FalseColoring::SOMGRAD)
		{
			theButton->setVisible(true);
		}
		break;
	case FalseColoringState::CALCULATING:
		theButton->setText("Cancel Computation");
		theButton->setVisible(true);
		break;
	case FalseColoringState::ABORTING:
		theButton->setVisible(true);
		break;
	default:
		assert(false);
		break;
	}
}

void FalseColorDock::enterState(FalseColoring::Type coloringType, FalseColoringState::Type state)
{
//	GGDBGM(coloringType << " entering state " << state << endl);
	coloringState[coloringType] = state;
}

void FalseColorDock::processVisibilityChanged(bool visible)
{
	dockVisible = visible;
	if(dockVisible) {
		requestColoring(selectedColoring());
	}
}

void FalseColorDock::processColoringOutOfDate(FalseColoring::Type coloringType)
{
	coloringUpToDate[coloringType] = false;
	if(dockVisible) {
		requestColoring(selectedColoring());
	}
}

void FalseColorDock::processCalculationProgressChanged(FalseColoring::Type coloringType, int percent)
{
	coloringProgress[coloringType] = percent;
	updateProgressBar();
}
