/*******************************************************************/
/*                                                                 */
/*                      ADOBE CONFIDENTIAL                         */
/*                   _ _ _ _ _ _ _ _ _ _ _ _ _                     */
/*                                                                 */
/* Copyright 2018 Adobe Systems Incorporated                       */
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

#ifndef PRSDKCOLORSEICODES_H
#define PRSDKCOLORSEICODES_H

#ifndef PRSDKTYPES_H
#include "PrSDKTypes.h"
#endif

#pragma pack(push, 1)

// Supported color Primaries
enum class PrColorPrimaries : csSDK_int32
{
	kBT709 = 1,				// Rec. 709 Primaries
	kBT470M = 4,			// Rec. ITU-R BT.470-6 System M (historical)
	kBT601_625 = 5,			// Rec. ITU-R BT.601-6 625 (PAL)
	kBT601_525 = 6,			// Rec. ITU-R BT.601-6 525 (NTSC)
	kSMPTE_240M = 7,		// functionally equivalent to BT.601-525, code value 6
	kGenericFilm = 8,		// Generic film
	kBT2020 = 9,			// Rec. ITU-R BT.2020-2
	kSMPTE_ST428_1 = 10,	// SMPTE ST 428-1
	kSMPTE_RP431 = 11,		// SMPTE ST 431-2
	kP3D65 = 12,			// SMPTE ST 432-1, P3D65
	kEBU3213 = 22,			// SMPTE EBU3213
	
	// Custom primaries not defined in ITU specifications.
	kSony_SGamut = 1010,		// Sony SGamut
	kSony_SGamut3 = 1011,		// Sony SGamut3
	kSony_SGamut3Cine = 1012,	// Sony SGamut3Cine
	kPanasonic_VGamut = 1020,	// Panasonic VGamut
	kCanon_CGamut = 1030		// Canon CGamut
};

// Supported Transfer Characteristics
enum class PrTransferCharacteristic : csSDK_int32
{
	kBT709 = 1,				// Rec. 709, functionally same as code values 6, 11, 14 and 15
	kBT470M = 4,			// Assumed display gamma 2.2
	kBT470BG = 5,			// Assumed display gamma 2.8
	kBT601 = 6,				// Rec. ITU-R BT.601-6 525 or 625, functionally same as code values 1, 11, 14 and 15
	kSMPTE_240M = 7,		// SMPTE 240M, functtioonallyy same as code values 1, 11, 14, 15
	kLinear = 8,			// Linear curve.
	kIEC61966_2_4 = 11,		// xvYCC, functionally same as code values 1, 6, 14 and 15
	kIEC61966_2_1 = 13,		// IEC 61966-2-1 sRGB or sYCC
	kBT2020a = 14,			// Rec. ITU-R BT.2020, functionally same as code values 1, 6, 11 and 15
	kBT2020b = 15,			// Rec. ITU-R BT.2020, functionally same as code values 1, 6, 11 and 14
	kBT2100PQ = 16,			// SMPTE ST 2084
	kST428_1 = 17,			// DCDM, SMPTE ST428 use Gamma of 2.6
	kBT2100HLG = 18,		// Rec. 2100 HLG
	
	// Custom curves not defined in ITU specifications.
	kSony_SLog2 = 1000,		// Sony SLog2
	kSony_SLog3 = 1001,		// Sony SLog3
	kPanasonic_VLog = 1010,	// Panasonic VLog
	kCanon_CLog2 = 1020,	// Canon CLog2
	kCanon_CLog3 = 1021,	// Cannon CLog3
	kCanon_CLog = 1022		// Canon CLog
};

// Supported Matrix equations - used for YCC <-> RGB conversions
enum class PrMatrixEquations : csSDK_int32
{
	kIdentity = 0,			// Identity matrix
	kBT709 = 1,				// Rec. ITU-R BT.709-6
	kFCCTitle47 = 4,		// United States Federal Communications Commission Title 47
	kBT601_625 = 5,			// Rec. ITU-R BT.601-6 625, functionally same as code 6
	kBT601_525 = 6,			// Rec. ITU-R BT.601-6 525. functionally same as code 5
	kSMPTE_240M = 7,		// SMPTE 240M
	kBT2020NCL = 9,			// Rec. ITU-R BT.2020-2 non-constant luminance system
	kBT2020CL = 10,			// Rec. ITU-R BT.2020-2 constant luminance system
	kBT2100ICtCp = 14		// Rec. 2100 ICtCp
};

// Supported bit depths - Future use, align with PixelFormat for now.
enum class PrEncodingBitDepth : csSDK_int32
{
	k8u = 8,
	k10u = 10,
	k12u = 12,
	k15u = 15,
	k16u = 16,
	k32f = 32
};



// video color space encoding
struct prSEIColorCodesRec
{
	// first 3 are based on SEI codes from Rec. H-265
	csSDK_int32	colorPrimariesCode;
	csSDK_int32	transferCharacteristicCode;
	csSDK_int32	matrixEquationsCode;
	csSDK_int32	bitDepth;		// For future, align with PixelFormat for now
	prBool		isFullRange;	// full/narrow range. For future, align with PixelFormat for now
	prBool		isRGB;			// RGB/YUV, For future, align with PixelFormat for now
	prBool		isSceneReferred;
	// default init to Rec. 709
	prSEIColorCodesRec() :
		colorPrimariesCode(1),			// 709 color primaries
		transferCharacteristicCode(1),	// 709 transfer curve
		matrixEquationsCode(1),			// 709 matrix coefficients
		bitDepth(8),
		isFullRange(false),
		isRGB(false),
		isSceneReferred(false)	// default is display-referred
	{}
	prSEIColorCodesRec(
		csSDK_int32 inColorPrimariesCode,
		csSDK_int32 inTransferCharacteristicCode,
		csSDK_int32 inMatrixEquationsCode,
		csSDK_int32 inBitDepth,
		prBool		inIsFullRange,
		prBool		inIsRGB,
		prBool		inIsSceneReferred) :
			colorPrimariesCode(inColorPrimariesCode),
			matrixEquationsCode(inMatrixEquationsCode),
			transferCharacteristicCode(inTransferCharacteristicCode),
			bitDepth(inBitDepth),
			isFullRange(inIsFullRange),
			isRGB(inIsRGB),
			isSceneReferred(inIsSceneReferred)
	{}
};

#pragma pack(pop)

#endif	// PRSDKCOLORSEICODES_H
