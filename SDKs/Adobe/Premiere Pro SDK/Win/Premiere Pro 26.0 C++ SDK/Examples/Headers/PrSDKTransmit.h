/*******************************************************************/
/*                                                                 */
/*                      ADOBE CONFIDENTIAL                         */
/*                   _ _ _ _ _ _ _ _ _ _ _ _ _                     */
/*                                                                 */
/* Copyright 2011 Adobe Systems Incorporated                       */
/* All Rights Reserved.                                            */
/*                                                                 */
/* NOTICE:  All information contained herein is, and remains the   */
/* property of Adobe Systems Incorporated and its suppliers, if    */
/* any.  The intellectual and technical concepts contained         */
/* herein are proprietary to Adobe Systems Incorporated and its    */
/* suppliers and may be covered by U.S. and Foreign Patents,       */
/* patents in process, and are protected by trade secret or        */
/* copyright law.  Dissemination of this information or            */
/* reproduction of this material is strictly forbidden unless      */
/* prior written permission is obtained from Adobe Systems         */
/* Incorporated.                                                   */
/*                                                                 */
/*******************************************************************/



//	This file is part of the public Premiere SDK.



#ifndef PRSDKTRANSMIT_H
#define PRSDKTRANSMIT_H


#include "PrSDKActivationEvent.h"
#include "PrSDKAudioSuite.h"
#include "PrSDKColorProfile.h"
#include "PrSDKPlayModule.h"
#include "PrSDKPlugSuites.h"
#include "PrSDKQuality.h"
#include "PrSDKStreamLabel.h"
#include "PrSDKTimeSuite.h"


#pragma pack(push, 1)
#ifdef __cplusplus
extern "C" {
#endif


/**
**	Interface version
*/
#define tmInterfaceVersion1 1 // 6.0
#define tmInterfaceVersion2 2 // 9.0
#define tmInterfaceVersion3 3
#define tmInterfaceVersion4 4
#define tmInterfaceVersion tmInterfaceVersion4


/**
**	Transmit return codes
*/
typedef enum PrTransmitReturnValue
{
	tmResult_Success = 0,
	tmResult_ContinueIterate = 1,

	tmResult_ErrorUnknown = -1,
	tmResult_ErrorMemory = -2,
	tmResult_ErrorInvalidArgument = -3,
	tmResult_ErrorUnsupported = -4
} tmResult;


/**
**	Transmit standard parameters
*/
typedef struct
{
	csSDK_int32 inPluginIndex;

	PrMemoryPtr ioSerializedPluginData; // may be written by plugin in Startup or Setup, must be serializable by the host
	csSDK_size_t ioSerializedPluginDataSize;

	void* ioPrivatePluginData; // may be written by plugin in Startup or Setup

	piSuitesPtr piSuites;
} tmStdParms;

/**
**	Transmit plug-in information
*/
typedef struct
{
	prPluginID outIdentifier; // persistent plug-in identifier
	unsigned int outPriority; // 0 is default, higher priority wins

	// audio
	prBool outAudioAvailable;
	prBool outAudioDefaultEnabled;

	// clock
	prBool outClockAvailable;

	// video
	prBool outVideoAvailable;
	prBool outVideoDefaultEnabled;

	// ui
	prUTF16Char outDisplayName[256];
	prBool outHideInUI;
	prBool outHasSetup;

	// the SDK version with which the plug-in was compiled
	csSDK_int32 outInterfaceVersion;

	// push audio - if kPrTrue, push audio functionality is supported
	prBool outPushAudioAvailable;	// since SDK version 4

	// streaming - if true, the plug-in streams audio and or video (e.g. via network)
	prBool outHasStreaming;			// since SDK version 4

} tmPluginInfo;


/**
**	Transmit instance information
*/
typedef struct
{
	csSDK_int32 inInstanceID;

	PrTimelineID inTimelineID; // may be 0
	PrPlayID inPlayID; // may be 0

	prBool inHasAudio;
	csSDK_uint32 inNumChannels;
	PrAudioChannelLabel inChannelLabels[16];
	PrAudioSampleType inAudioSampleType;
	float inAudioSampleRate;

	prBool inHasVideo;
	csSDK_int32 inVideoWidth;
	csSDK_int32 inVideoHeight;
	csSDK_int32 inVideoPARNum;
	csSDK_int32 inVideoPARDen;
	PrTime inVideoFrameRate;
	prFieldType inVideoFieldType;

	void* ioPrivateInstanceData; // may be written by plug-in in CreateInstance, need not be serializable by the host
} tmInstance;


/**
**	Transmit instance query
*/
typedef struct
{
	csSDK_int32 outWidth; // 0 for any
	csSDK_int32 outHeight; // 0 for any
	csSDK_int32 outPARNum; // 0 for any
	csSDK_int32 outPARDen; // 0 for any
	prFieldType outFieldType; // prFieldsAny for any
	PrPixelFormat outPixelFormat; // PrPixelFormat_Any for any
	PrSDKString outStreamLabel; // {0} for normal
	PrTime outLatency; // all modes must have the same latency, it is strongly suggested to keep latency at or below 5 frames
	ColorSpaceRec outColorSpaceRec; // default to BT 709 full range 32f
} tmVideoMode;

const csSDK_uint32 kMaxTransmitAudioChannels = 16;
typedef struct
{
	float outAudioSampleRate;
	csSDK_uint32 outMaxBufferSize;
	csSDK_uint32 outNumChannels;
	PrAudioChannelLabel outChannelLabels[kMaxTransmitAudioChannels];
	PrTime outLatency;
	PrSDKString outAudioOutputNames[kMaxTransmitAudioChannels];
} tmAudioMode;


/**
**	Transmit playback clock
*/
typedef void (*tmClockCallback)(void* inContext, PrTime inRelativeTimeAdjustment);
typedef void (*tmDroppedFrameCallback)(void* inContext, csSDK_int64 inNewDroppedFrames);
typedef struct
{
	// To be called when the time changes with a non-speed adjusted amount to increment the clock by
	tmClockCallback inClockCallback;
	void* inCallbackContext;

	PrTime inStartTime;
	pmPlayMode inPlayMode;
	float inSpeed; // 1.0 is normal speed, -2.0 is double speed backwards

	// inInTime, inOutTime & inLoop are informational only
	// and will be handled by the host
	PrTime inInTime;
	PrTime inOutTime;
	prBool inLoop;

	// To report frames pushed to the plug-in but not delivered to the device.
	// If all work is done on the transmit thread then this should never need
	// to be called as the host will count frames not pushed to the plug-in.
	tmDroppedFrameCallback inDroppedFrameCallback;

	// The host will automatically take care of accouting for offsets as
	// chosen by the user in the preferences by sending frames early,
	// however if the plug-in manually lines up a/v times these may need
	// to be taken into account
	PrTime inAudioOffset;
	PrTime inVideoOffset;
} tmPlaybackClock;

/**
**	Streaming state callback
**	Networking plug-ins call this when the streaming state changes,
**	either after the host enables/disables streaming or when the
**	connection state changes from 0 to N connections or vice versa.
*/
typedef void (*tmStreamingStateChangedCallback)(void* inContext);

/**
**	Transmit video
*/
typedef struct
{
	PPixHand inFrame; // must be disposed by plug-in
	PrSDKStreamLabel inStreamLabel;
} tmLabeledFrame;
typedef struct
{
	PrTime inTime; // negative for immediate
	pmPlayMode inPlayMode;
	PrRenderQuality inQuality;

	const tmLabeledFrame* inFrames;
	csSDK_size_t inFrameCount;
} tmPushVideo;

/**
**	Transmit audio via push
*/
typedef struct
{
	PrTime inTime;
	float** inBuffers;
	csSDK_uint32 inNumSamples;
	csSDK_uint32 inNumChannels;
} tmPushAudio;

/**
**	Transmit module definition. 0 may be filled in for any unsupported calls.
**	Thread safety is defined per module, only a single thread will enter a
**	module at a time, with the exception of PushAudio().
**
**	Transmit plug-ins supporting audio should use PrSDKPlayModuleAudioSuite to
**	pull audio in plug-in mode using tmInstance::inPlayID if available. The host
**	will start and stop the audio suite, only GetNextAudioBuffer should be called.
**	See also PrSDKAudioSuite for conversions between common audio formats.
**	Currently audio transmit plug-ins must also implement a clock source.
*/
typedef struct
{
	/**
	**	Initialize or terminate a transmit plug-in and fill in basic plug-in
	**	info. tmResult_ContinueIterate may be returned to support multiple
	**	transmit plug-ins within the same module. ioPrivatePluginData,
	**	ioSerializedPluginData & ioSerializedPluginDataSize may be written from
	**	Startup. ioPrivatePluginData should be disposed in Shutdown.
	**	ioSerializedPluginData must be allocated with PrNewPtr and will be disposed
	**	by the host. This must be flat memory that can be serialized by by the host
	**	and will be already filled in when Startup is called if previously available.
	*/
	tmResult (*Startup)(
		tmStdParms* ioStdParms,
		tmPluginInfo* outPluginInfo);
	tmResult (*Shutdown)(
		tmStdParms* ioStdParms);


	/**
	**	Prompt the user for any setup needed for the transmit plug-in. Will only
	**	be called if the plug-in returned outHasSetup. ioSerializedPluginData &
	**	ioSerializedPluginDataSize may be written from this call.
	*/
	tmResult (*SetupDialog)(
		tmStdParms* ioStdParms,
		prParentWnd inParent);

	/**
	**	Will be called regularly on the first plug-in of a module to allow
	**	rebuilding on state changes. If outResetModule is set to true, all open
	**	plug-ins will be shutdown and started up again.
	*/
	tmResult (*NeedsReset)(
		const tmStdParms* inStdParms,
		prBool* outResetModule);

	/**
	**	Creates or dispose an instance of a transmit plug-in. inPlayID and
	**	inTimelineID may be 0 if not driven by a player. Multiple instances
	**	may be created at the same time. ioPrivateInstanceData may be written
	**	from CreateInstance and disposed in DisposeInstance.
	*/
	tmResult (*CreateInstance)(
		const tmStdParms* inStdParms,
		tmInstance* ioInstance);
	tmResult (*DisposeInstance)(
		const tmStdParms* inStdParms,
		tmInstance* ioInstance);

	/**
	**	Query properties of an instance writing result into outProperty.
	**		Only one audio mode is currently supported
	**      The audio output names (PrSDKString) in tmAudioMode should be
	**       allocated by the plug-in and NOT be disposed by the plug-in.
	**       The host will take care of disposing these strings. These must be
	**       displayable names of physical audio outputs like "XYZ HD Speaker 1"
	*/
	tmResult (*QueryAudioMode)(
		const tmStdParms* inStdParms,
		const tmInstance* inInstance,
		csSDK_int32 inQueryIterationIndex,
		tmAudioMode* outAudioMode);
	tmResult (*QueryVideoMode)(
		const tmStdParms* inStdParms,
		const tmInstance* inInstance,
		csSDK_int32 inQueryIterationIndex,
		tmVideoMode* outVideoMode);

	/**
	**	Activate or deactivate a transmit instance, for example during
	**	application suspend or switching between monitors. Audio and
	**	video may be independently activated.
	*/
	tmResult (*ActivateDeactivate)(
		const tmStdParms* inStdParms,
		const tmInstance* inInstance,
		PrActivationEvent inActivationEvent,
		prBool inAudioActive,
		prBool inVideoActive);

	/**
	**	Start or stop a clock for playback. Will only be called if the plug-in
	**	returned outHasClock. The provided callback must be called each time
	**	the time changes. Start may be called multiple times without a stop in
	**	between to update playback parameters, for example if the speed changes
	**	during playback. Invoke the callback immediately during StartPlaybackClock
	**	with a negative number for preroll, but do not use this to wait for frames.
	**	If video latency is specified, up to the latency's amount of frame marked
	**	as playmode_Playing will be sent before StartPlaybackClock is called.
	*/
	tmResult (*StartPlaybackClock)(
		const tmStdParms* inStdParms,
		const tmInstance* inInstance,
		const tmPlaybackClock* inClock);
	tmResult (*StopPlaybackClock)(
		const tmStdParms* inStdParms,
		const tmInstance* inInstance);

	/**
	**	Asynchronously pushes video to a transmit instance. Will only be called
	**	if the plug-in returned outHasVideo. The list of video frames passed to
	**	the plug-in will be negotiated based on the properties returned from
	**	QueryVideoMode. The plug-in is responsible for disposing of all passed in ppix.
	*/
	tmResult (*PushVideo)(
		const tmStdParms* inStdParms,
		const tmInstance* inInstance,
		const tmPushVideo* inPushVideo);

	/**
	** Transmit interface version 4 functions
	*/

	/**
	**	If the plug-in reports outPushAudioAvailable as true, the device will be
	**	enabled for a "secondary" mode where audio from the "primary" or "clock"
	**	device is pushed to this one.
	**	This is especially useful for remote devices.
	**	PushAudio APIs will only be used in this "mirror" case.
	**	StartPushAudio() initializes the device for subsequent PushAudio() calls.
	**	Unlike StartPlaybackClock, StartPushAudio() is only called
	**	once until StopPushAudio() is called.
	**	PushAudio() is called whenever the desired buffer size is
	**
	*/
	tmResult (*StartPushAudio)(
		const tmStdParms* inStdParms,
		const tmInstance* inInstance,
		PrTime inStartTime,
		float inSpeed,
		PrTime inInTime,
		PrTime inOutTime,
		prBool inLoop,
		prBool inScrubbing,
		csSDK_uint32* outSamplesPerFrame);

	/**
	**	Note: PushAudio() may be called even if another API
	**	is called at the same time.
	*/
	tmResult (*PushAudio)(
		const tmStdParms* inStdParms,
		const tmInstance* inInstance,
		const tmPushAudio* inPushAudio);

	/**
	**	StopPushAudio() is called when playback via
	**	PushAudio() ends.
	*/
	tmResult (*StopPushAudio)(
		const tmStdParms* inStdParms,
		const tmInstance* inInstance);


	/**
	**	SetStreamingStateChangedCallback()
	**	Set the host callback for notification streaming state changes, i.e.
	**	when the plug-in becomes active or inactive due to changes connections
	**	or enablement from the host.
	*/
	tmResult (*SetStreamingStateChangedCallback)(
		const tmStdParms* inStdParms,
		void* inContext,
		tmStreamingStateChangedCallback inCallback);

	/**
	**	EnableStreaming()
	**	Enable/disable streaming to connected clients without loading or unloading
	**	the plug-in.
	*/
	tmResult (*EnableStreaming)(
		const tmStdParms* inStdParms,
		prBool inEnabled);

	/**
	**	IsStreamingEnabled()
	**	Returns whether streaming is enabled in *outEnabled.
	*/
	tmResult (*IsStreamingEnabled)(
		const tmStdParms* inStdParms,
		prBool* outEnabled);

	/**
	**	IsStreamingActive()
	**	Returns whether the plug-in is actively streaming, i.e. streaming is enabled
	**	and the plug-in has active connections.
	*/
	tmResult (*IsStreamingActive)(
		const tmStdParms* inStdParms,
		prBool* outActive);

} tmModule;


/**
** Entry point.
*/
#define tmEntryPointName "xTransmitEntry"
typedef tmResult (*tmEntryFunc)(
	csSDK_int32 inInterfaceVersion, // tmInterfaceVersion
	prBool inLoadModule, // tmEntryFunc will be called once on load, and once on unload
	piSuitesPtr piSuites,
	tmModule* outModule);


#ifdef __cplusplus
}
#endif
#pragma pack(pop)



#endif
