/*************************************************************************
* ADOBE CONFIDENTIAL
* ___________________
*
* Copyright 2019 Adobe
* All Rights Reserved.
*
* NOTICE: All information contained herein is, and remains
* the property of Adobe and its suppliers, if any. The intellectual
* and technical concepts contained herein are proprietary to Adobe
* and its suppliers and are protected by all applicable intellectual
* property laws, including trade secret and copyright laws.
* Dissemination of this information or reproduction of this material
* is strictly forbidden unless prior written permission is obtained
* from Adobe.
**************************************************************************/

#ifndef PRSDKCOLORMANAGEMENTSUITE_H
#define PRSDKCOLORMANAGEMENTSUITE_H

#ifndef PRSDKTYPES_H
#include "PrSDKTypes.h"
#endif

#ifndef PRSDKMALERRORS_H
#include "PrSDKMALErrors.h"
#endif

#ifndef PRSDKCOLORPROFILE_H
#include "PrSDKColorProfile.h"
#endif

#pragma pack(push, 1)
#ifdef __cplusplus
extern "C" {
#endif

#define kPrSDKColorManagementSuite			"Color Management Suite"
#define kPrSDKColorManagementSuiteVersion1	1
#define kPrSDKColorManagementSuiteVersion	kPrSDKColorManagementSuiteVersion1

typedef struct
{
	/**
	**	@param1 opaque color space id passed in by the host
	**	@param2 color space type for the color space id in param1
	**	It may be kPrSDKColorSpaceType_Undefined. Plug-in
	**	should handle it.
	**	@return error code. If success, returns malNoError
	*/
	prSuiteError (*GetColorSpaceTypeForColorSpace)(
		const PrSDKColorSpaceID *inSDKColorSpaceID,
		PrSDKColorSpaceType		*outSDKColorSpaceType);
		
	/**
	**	@param1 opaque color space id passed in by the host
	**	@param2 flag that indicates whether there is an ICC 
	**	equivalent representation for the color space in param1
	**	@return error code. If success, returns malNoError
	*/
	prSuiteError (*HasICCEquivalentColorSpaceForColorSpace)(
		const PrSDKColorSpaceID *inSDKColorSpaceID,
		prBool					*outHasICCEquivalentColorSpace);
		
	/**
	**	@param1 opaque color space id passed in by the host
	**	@param2 opaque color space id of the ICC color
	**	space that is equivalent to the color space in param1
	**	@return error code. If success, returns malNoError
	*/
	prSuiteError (*GetICCEquivalentColorSpaceForColorSpace)(
		const PrSDKColorSpaceID *inSDKColorSpaceID,
		PrSDKColorSpaceID		*outSDKICCColorSpaceID);
	
	/**
	**	@param1 opaque color space id passed in by the host
	**	@param2 filled in SEI color codes rec if color space
	**	in param1 is of kPrSDKColorSpaceType_SEITags
	**	@return error code. If success, returns malNoError
	*/
	prSuiteError (*GetSEIColorCodesForColorSpace)(
		const PrSDKColorSpaceID *inSDKColorSpaceID,
		prSEIColorCodesRec		*outSEIColorCodesRec);
	
	/**
	**	@param1 opaque color space id passed in by the host
	**	@param2 filled in with size of ICC profile for the
	**	color space in param1 if the color space is of
	**	kPrSDKColorSpaceType_ICC.
	**	@return error code. If success, returns malNoError
	*/
	prSuiteError (*GetICCProfileSizeForColorSpace)(
		const PrSDKColorSpaceID *inSDKColorSpaceID,
		csSDK_int32				*outICCProfileSize);
	
	/**
	**	@param1 opaque color space id passed in by the host
	**	@param2 pointer to a memory block allocated by caller
	**	based on the size from GetICCProfileSizeForColorSpace.
	**	ICC profile as a binary data is copied to the ptr in
	**	param2 if color space in param1 is of kPrSDKColorSpaceType_ICC.
	**	Caller is responsible for disposing memory in param2.
	**	@return error code. If success, returns malNoError
	*/
	prSuiteError (*GetICCProfileForColorSpace)(
	   const PrSDKColorSpaceID *inSDKColorSpaceID,
	   PrMemoryPtr				ioICCProfileData);
	   
	/**
	**	@param1 predefined color space token from PrSDKColorSpaces.h
	**	@param2 display name of the color space from param1 as a null 
	**	terminated unicode string.
	**	@return error code. If success, return malNoError 
	*/
	prSuiteError (*GetDisplayNameForPredefinedColorSpace)(
		const char*	inSDKPredefinedColorSpace,
		prUTF16Char	outDisplayName[256]);
	
		
} PrSDKColorManagementSuite;

#ifdef __cplusplus
}
#endif

#pragma pack(pop)


#endif	// PRSDKCOLORMANAGEMENTSUITE_H
