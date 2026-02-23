/*******************************************************************/
/*                                                                 */
/*                      ADOBE CONFIDENTIAL                         */
/*                   _ _ _ _ _ _ _ _ _ _ _ _ _                     */
/*                                                                 */
/* Copyright 2009 Adobe Systems Incorporated                       */
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


#ifndef PRSDKACCELERATEDRENDERINVOCATIONSUITE_H
#define PRSDKACCELERATEDRENDERINVOCATIONSUITE_H


#ifndef PRSDKTYPES_H
#include "PrSDKTypes.h"
#endif

#ifndef PRSDKACCELERATEDRENDER_H
#include "PrSDKAcceleratedRender.h"
#endif

#ifndef PRSDKRENDERERIDS_H
#include "PrSDKRendererIDs.h"
#endif

#pragma pack(push, 1)

#ifdef __cplusplus
extern "C" {
#endif

#define kPrSDKAcceleratedRenderInvocationSuite			"MediaCore Accelerated Render Invocation Suite"
#define kPrSDKAcceleratedRenderInvocationSuiteVersion3	3
#define kPrSDKAcceleratedRenderInvocationSuiteVersion4	4	// CS 13.0; display color management and captioning
#define kPrSDKAcceleratedRenderInvocationSuiteVersion	kPrSDKAcceleratedRenderInvocationSuiteVersion4

/**
**	Access to invoking specific accelerated renderers by ID
*/
typedef struct 
{
	/**
	**	Get the ID of the currently selected sequence renderer.
	**
	**	@param outRendererID - GUID as returned from arSelector_Startup
	**		nil when software renderer is selected.
	*/
	prSuiteError (*GetCurrentAcceleratedSequenceRendererID)(
		prPluginID* outRendererID);

	/**
	**	Creates an accelerated renderer by ID. This must be disposed with DisposeAcceleratedSequenceRenderer.
	**
	**	@param inRendererID - GUID as returned from arSelector_Startup
	**	@param inSequence - a top level sequence 
	*/
	prSuiteError (*CreateAcceleratedSequenceRenderer)(
		prPluginID* inRendererID,
		PrTimelineID inSequence,
		prBool inUsePreviews,
		csSDK_uint32* outRendererInstanceID);

	/**
	**	Disposes an accelerated renderer instance
	*/
	prSuiteError (*DisposeAcceleratedSequenceRenderer)(
		csSDK_uint32 inRendererInstanceID);

	/**
	**	Initiates a render with the given accelerated renderer.
	**
	**	@param ioRenderData - ioRenderData->inRequestID will be filled inside call 
	*/
	prSuiteError (*InitiateRender)(
		csSDK_uint32 inRendererInstanceID,
		arRenderRequest* ioRenderData);

	/**
	**	Cancel an outstanding render
	*/
	prSuiteError (*CancelRender)(
		csSDK_uint32 inRendererInstanceID,
		csSDK_uint32 inRequestID);

	/**
	**	Query properties about a segment
	*/
	prSuiteError (*QuerySegmentProperties)(
		csSDK_uint32 inRendererInstanceID,
		PrTime inStartTime,
		PrTime* outEndTime,
		arSegmentStatus* outStatus,
		PrPixelFormat* outPixelFormats,
		csSDK_int32* ioPixelFormatCount);
	
	/**
	**	Creates an accelerated renderer by ID. This must be disposed with DisposeAcceleratedSequenceRenderer.
	**
	**	@param inRendererID - GUID as returned from arSelector_Startup
	**	@param inSequence - a top level sequence 
	*/
	prSuiteError (*CreateAcceleratedSequenceRendererWithStreamLabel)(
		prPluginID* inRendererID,
		PrTimelineID inSequence,
		prBool inUsePreviews,
		PrSDKStreamLabel inStreamLabel,
		csSDK_uint32* outRendererInstanceID);
	
	/**
	**	Get the name of a sequence renderer.
	*/
	prSuiteError (*GetAcceleratedSequenceRendererDisplayName)(
		prPluginID* inRendererID,
		prUTF16Char outDisplayName[256]);

	/**
	**	Initiates a render with the given accelerated renderer.
	**
	**	@param ioRenderData - ioRenderData->inRequestID will be filled inside call
	*/
	prSuiteError(*InitiateRender2)(
		csSDK_uint32 inRendererInstanceID,
		arRenderRequest2* ioRenderData);
	
	/**
	 **	Get the current state of display color management
	*/
	prSuiteError(*GetEnabledDisplayColorManagement)(
		prBool *outEnabledDisplayColorManagement);
	
} PrSDKAcceleratedRenderInvocationSuite;

#ifdef __cplusplus
}
#endif

#pragma pack(pop)


#endif
