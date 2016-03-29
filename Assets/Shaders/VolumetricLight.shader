﻿//  Copyright(c) 2016, Michal Skalsky
//  All rights reserved.
//
//  Redistribution and use in source and binary forms, with or without modification,
//  are permitted provided that the following conditions are met:
//
//  1. Redistributions of source code must retain the above copyright notice,
//     this list of conditions and the following disclaimer.
//
//  2. Redistributions in binary form must reproduce the above copyright notice,
//     this list of conditions and the following disclaimer in the documentation
//     and/or other materials provided with the distribution.
//
//  3. Neither the name of the copyright holder nor the names of its contributors
//     may be used to endorse or promote products derived from this software without
//     specific prior written permission.
//
//  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY
//  EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
//  OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.IN NO EVENT
//  SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
//  SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT
//  OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
//  HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR
//  TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE,
//  EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.



Shader "Sandbox/VolumetricLight"
{
	Properties
	{
		_MainTex ("Texture", 2D) = "white" {}
		_ZTest ("ZTest", Float) = 0
	}
	SubShader
	{
		Tags { "RenderType"="Opaque" }
		LOD 100

		CGINCLUDE

		#define SHADOWS_NATIVE

		#include "UnityCG.cginc"
		#include "UnityDeferredLibrary.cginc"

		sampler3D _NoiseTexture;
		sampler2D _DitherTexture;

		//sampler2D _ShadowMapTexture;

		struct appdata
		{
			float4 vertex : POSITION;
		};

		float4x4 _WorldViewProj;
		float4x4 _WorldView;
		float4x4 _MyLightMatrix0;
		float4x4 _MyWorld2Shadow;

		// x: density, y: mie g, z: range w: unused
		float4 _VolumetricLight;

		// x: scale, y: intensity, z: intensity offset
		float4 _NoiseData;
		float4 _NoiseVelocity;
		// x: min height, y: height range, z: min height intensity, w: height intensity range
		float4 _HeightFog;

		int _SampleCount;

		struct v2f
		{
			float4 pos : SV_POSITION;
			float4 uv : TEXCOORD0;
			float3 ray : TEXCOORD1;
			float3 wpos : TEXCOORD2;
		};

		v2f vert(appdata v)
		{
			v2f o;
			o.pos = mul(_WorldViewProj, v.vertex);
			o.uv = ComputeScreenPos(o.pos);
			o.ray =  mul(_WorldView, v.vertex).xyz * float3(-1, -1, 1);
			o.wpos = mul(_Object2World, v.vertex);
			return o;
		}

		v2f vertQuad(appdata v)
		{
			v2f o;
			o.pos = mul(UNITY_MATRIX_MVP, v.vertex);
			o.uv = ComputeScreenPos(o.pos);
			o.ray = mul(UNITY_MATRIX_MV, v.vertex).xyz * float3(-1, -1, 1);
			o.wpos = mul(_Object2World, v.vertex);
			return o;
		}

		//-----------------------------------------------------------------------------------------
		// GetCascadeWeights_SplitSpheres
		//-----------------------------------------------------------------------------------------
		inline fixed4 GetCascadeWeights_SplitSpheres(float3 wpos)
		{
			float3 fromCenter0 = wpos.xyz - unity_ShadowSplitSpheres[0].xyz;
			float3 fromCenter1 = wpos.xyz - unity_ShadowSplitSpheres[1].xyz;
			float3 fromCenter2 = wpos.xyz - unity_ShadowSplitSpheres[2].xyz;
			float3 fromCenter3 = wpos.xyz - unity_ShadowSplitSpheres[3].xyz;
			float4 distances2 = float4(dot(fromCenter0, fromCenter0), dot(fromCenter1, fromCenter1), dot(fromCenter2, fromCenter2), dot(fromCenter3, fromCenter3));
#if !defined(SHADER_API_D3D11)
			fixed4 weights = float4(distances2 < unity_ShadowSplitSqRadii);
			weights.yzw = saturate(weights.yzw - weights.xyz);
#else
			fixed4 weights = float4(distances2 >= unity_ShadowSplitSqRadii);
#endif
			return weights;
		}

		//-----------------------------------------------------------------------------------------
		// GetCascadeShadowCoord
		//-----------------------------------------------------------------------------------------
		inline float4 GetCascadeShadowCoord(float4 wpos, fixed4 cascadeWeights)
		{
#if defined(SHADER_API_D3D11)
			return mul(unity_World2Shadow[(int)dot(cascadeWeights, float4(1, 1, 1, 1))], wpos);
#else
			float3 sc0 = mul(unity_World2Shadow[0], wpos).xyz;
			float3 sc1 = mul(unity_World2Shadow[1], wpos).xyz;
			float3 sc2 = mul(unity_World2Shadow[2], wpos).xyz;
			float3 sc3 = mul(unity_World2Shadow[3], wpos).xyz;
			return float4(sc0 * cascadeWeights[0] + sc1 * cascadeWeights[1] + sc2 * cascadeWeights[2] + sc3 * cascadeWeights[3], 1);
#endif
		}

		//-----------------------------------------------------------------------------------------
		// UnityDeferredComputeShadow2
		//-----------------------------------------------------------------------------------------
		half UnityDeferredComputeShadow2(float3 vec, float fadeDist, float2 uv)
		{
#if defined(SHADOWS_DEPTH) || defined(SHADOWS_SCREEN) || defined(SHADOWS_CUBE)
			float fade = fadeDist * _LightShadowData.z + _LightShadowData.w;
			fade = saturate(fade);
#endif

#if defined(SPOT)
#if defined(SHADOWS_DEPTH)
			float4 shadowCoord = mul(_MyWorld2Shadow, float4(vec, 1));
				return saturate(UnitySampleShadowmap(shadowCoord) + fade);
#endif //SHADOWS_DEPTH
#endif

#if defined (DIRECTIONAL) || defined (DIRECTIONAL_COOKIE)
#if defined(SHADOWS_SCREEN)
			return saturate(tex2D(_ShadowMapTexture, uv).r + fade);
#endif
#endif //DIRECTIONAL || DIRECTIONAL_COOKIE

#if defined (POINT) || defined (POINT_COOKIE)
#if defined(SHADOWS_CUBE)
			return UnitySampleShadowmap(vec);
#endif //SHADOWS_CUBE
#endif

			return 1.0;
		}

		UNITY_DECLARE_SHADOWMAP(_CascadeShadowMapTexture);
		
		//-----------------------------------------------------------------------------------------
		// GetLightAttenuation
		//-----------------------------------------------------------------------------------------
		float GetLightAttenuation(float3 wpos)
		{
			float atten = 0;
#if defined (DIRECTIONAL) || defined (DIRECTIONAL_COOKIE)
			atten = 1;
#if defined (SHADOWS_DEPTH)
			// sample cascade shadow map
			float4 cascadeWeights = GetCascadeWeights_SplitSpheres(wpos);
			bool inside = dot(cascadeWeights, float4(1, 1, 1, 1)) < 4;
			float4 samplePos = GetCascadeShadowCoord(float4(wpos, 1), cascadeWeights);

			atten = inside ? UNITY_SAMPLE_SHADOW(_CascadeShadowMapTexture, samplePos.xyz) : 1.0f;
			//atten = inside ? tex2Dproj(_ShadowMapTexture, float4((samplePos).xyz, 1)).r : 1.0f;
#endif
#if defined (DIRECTIONAL_COOKIE)
			// NOT IMPLEMENTED
#endif
#elif defined (SPOT)	
			float3 tolight = _LightPos.xyz - wpos;
			half3 lightDir = normalize(tolight);

			float4 uvCookie = mul(_MyLightMatrix0, float4(wpos, 1));
			// negative bias because http://aras-p.info/blog/2010/01/07/screenspace-vs-mip-mapping/
			atten = tex2Dbias(_LightTexture0, float4(uvCookie.xy / uvCookie.w, 0, -8)).w;
			atten *= uvCookie.w < 0;
			float att = dot(tolight, tolight) * _LightPos.w;
			atten *= tex2D(_LightTextureB0, att.rr).UNITY_ATTEN_CHANNEL;

			atten *= UnityDeferredComputeShadow2(wpos, 0, float2(0, 0));
#elif defined (POINT) || defined (POINT_COOKIE)
			float3 tolight = wpos - _LightPos.xyz;
			half3 lightDir = -normalize(tolight);

			float att = dot(tolight, tolight) * _LightPos.w;
			atten = tex2D(_LightTextureB0, att.rr).UNITY_ATTEN_CHANNEL;

			atten *= UnityDeferredComputeShadow(tolight, 0, float2(0, 0));

#if defined (POINT_COOKIE)
			atten *= texCUBEbias(_LightTexture0, float4(mul(_MyLightMatrix0, half4(wpos, 1)).xyz, -8)).w;
#endif //POINT_COOKIE
#endif
#ifdef NOISE
			float noise = tex3D(_NoiseTexture, frac(wpos * _NoiseData.x + float3(_Time.y * _NoiseVelocity.x, 0, _Time.y * _NoiseVelocity.y)));
			noise = saturate(noise - _NoiseData.z) * _NoiseData.y;
			atten *= saturate(noise);
#endif

#ifdef HEIGHT_FOG
			float ratio = 1 - saturate((wpos.y - _HeightFog.x) / _HeightFog.y);
			atten *= ratio;// *_HeightFog.w + _HeightFog.z;
#endif

			return atten;
		}

		//-----------------------------------------------------------------------------------------
		// MieScattering
		//-----------------------------------------------------------------------------------------
		float MieScattering(float cosAngle)
		{
			float g = _VolumetricLight.y;
			float g2 = g * g;
			float res = (pow(1 - g, 2)) / (4 * 3.14 * pow(1 + g2 - (2 * g) * cosAngle, 3.0 / 2.0));
			return res;
		}

		//-----------------------------------------------------------------------------------------
		// RayMarch
		//-----------------------------------------------------------------------------------------
		float4 RayMarch(v2f i, float3 rayStart, float3 rayDir, float rayLength)
		{
			float2 interleavedPos = (fmod(floor(i.pos.xy), 4.0));
			float offset = tex2D(_DitherTexture, interleavedPos / 4.0 + float2(0.5 / 4.0, 0.5 / 4.0)).w;

			int stepCount = _SampleCount;

			float stepSize = rayLength / stepCount;
			float3 step = rayDir * stepSize;

			float3 currentPosition = rayStart + step * offset;

			float4 vlight = 0;

			[loop]
			for (int i = 0; i < stepCount; ++i)
			{
				float atten = GetLightAttenuation(currentPosition);

				float3 tolight = normalize(currentPosition - _LightPos.xyz);
				float cosAngle = dot(tolight, -rayDir);

				vlight += atten * stepSize * _LightColor * _VolumetricLight.x * MieScattering(cosAngle);

				currentPosition += step;
				
			}

			return max(0, vlight);
		}

		//-----------------------------------------------------------------------------------------
		// RayConeIntersect
		//-----------------------------------------------------------------------------------------
		float2 RayConeIntersect(in float3 f3ConeApex, in float3 f3ConeAxis, in float fCosAngle, in float3 f3RayStart, in float3 f3RayDir)
		{
			float inf = 10000;
			f3RayStart -= f3ConeApex;
			float a = dot(f3RayDir, f3ConeAxis);
			float b = dot(f3RayDir, f3RayDir);
			float c = dot(f3RayStart, f3ConeAxis);
			float d = dot(f3RayStart, f3RayDir);
			float e = dot(f3RayStart, f3RayStart);
			fCosAngle *= fCosAngle;
			float A = a*a - b*fCosAngle;
			float B = 2 * (c*a - d*fCosAngle);
			float C = c*c - e*fCosAngle;
			float D = B*B - 4 * A*C;

			if (D > 0)
			{
				D = sqrt(D);
				float2 t = (-B + sign(A)*float2(-D, +D)) / (2 * A);
				bool2 b2IsCorrect = c + a * t > 0 && t > 0;
				t = t * b2IsCorrect + !b2IsCorrect * (inf);
				return t;
			}
			else // no intersection
				return inf;
		}

		//-----------------------------------------------------------------------------------------
		// RayPlaneIntersect
		//-----------------------------------------------------------------------------------------
		float RayPlaneIntersect(in float3 planeNormal, in float planeD, in float3 rayOrigin, in float3 rayDir)
		{
			float NdotD = dot(planeNormal, rayDir);
			float NdotO = dot(planeNormal, rayOrigin);

			float t = -(NdotO + planeD) / NdotD;
			if (t < 0)
				t = 1000000;
			return t;
		}

		ENDCG

		// pass 0 - point light, camera inside
		Pass
		{
			ZTest Off
			Cull Front
			ZWrite Off
			Blend One One

			CGPROGRAM
			#pragma vertex vert
			#pragma fragment fragPointInside
#pragma target 5.0

			#define UNITY_HDR_ON

			#pragma shader_feature HEIGHT_FOG
			#pragma shader_feature NOISE
			#pragma shader_feature SHADOWS_CUBE
			#pragma shader_feature SHADOWS_NATIVE
			#pragma shader_feature POINT_COOKIE
			#pragma shader_feature POINT

			#ifdef SHADOWS_DEPTH
			#define SHADOWS_NATIVE
			#endif
						
			
			fixed4 fragPointInside(v2f i) : SV_Target
			{	
				float2 uv = i.uv.xy / i.uv.w;

				// read depth and reconstruct world position
				float depth = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, uv);			

				float3 rayStart = _WorldSpaceCameraPos;
				float3 rayEnd = i.wpos;

				float3 rayDir = (rayEnd - rayStart);
				float rayLength = length(rayDir);

				rayDir /= rayLength;

				rayLength = min(rayLength, LinearEyeDepth(depth));
				
				return RayMarch(i, rayStart, rayDir, rayLength);
			}
			ENDCG
		}

		// pass 1 - spot light, camera inside
		Pass
		{
			ZTest Off
			Cull Front
			ZWrite Off
			Blend One One

			CGPROGRAM
#pragma vertex vert
#pragma fragment fragPointInside
#pragma target 5.0

#define UNITY_HDR_ON

#pragma shader_feature HEIGHT_FOG
#pragma shader_feature NOISE
#pragma shader_feature SHADOWS_DEPTH
#pragma shader_feature SHADOWS_NATIVE
#pragma shader_feature SPOT

#ifdef SHADOWS_DEPTH
#define SHADOWS_NATIVE
#endif

			fixed4 fragPointInside(v2f i) : SV_Target
			{
				float2 uv = i.uv.xy / i.uv.w;

				// read depth and reconstruct world position
				float depth = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, uv);

				float3 rayStart = _WorldSpaceCameraPos;
				float3 rayEnd = i.wpos;

				float3 rayDir = (rayEnd - rayStart);
				float rayLength = length(rayDir);

				rayDir /= rayLength;

				rayLength = min(rayLength, LinearEyeDepth(depth));

				return RayMarch(i, rayStart, rayDir, rayLength);
			}
			ENDCG
		}

		// pass 2 - point light, camera outside
		Pass
		{
			//ZTest Off
			ZTest [_ZTest]
			Cull Back
			ZWrite Off
			Blend One One

			CGPROGRAM
			#pragma vertex vert
			#pragma fragment fragPointOutside
			#pragma target 5.0

			#define UNITY_HDR_ON

			#pragma shader_feature HEIGHT_FOG
			#pragma shader_feature SHADOWS_CUBE
			#pragma shader_feature NOISE
			//#pragma multi_compile POINT POINT_COOKIE
			#pragma shader_feature POINT_COOKIE
			#pragma shader_feature POINT

			fixed4 fragPointOutside(v2f i) : SV_Target
			{
				float2 uv = i.uv.xy / i.uv.w;

				// read depth and reconstruct world position
				float depth = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, uv);
			
				float3 rayStart = _WorldSpaceCameraPos;
				float3 rayEnd = i.wpos;

				float3 rayDir = (rayEnd - rayStart);
				float rayLength = length(rayDir);

				rayDir /= rayLength;

				float3 lightToCamera = _WorldSpaceCameraPos - _LightPos;

				float b = dot(rayDir, lightToCamera);
				float c = dot(lightToCamera, lightToCamera) - (_VolumetricLight.z * _VolumetricLight.z);

				float d = sqrt((b*b) - c);
				float start = -b - d;
				float end = -b + d;

				end = min(end, LinearEyeDepth(depth));

				rayStart = rayStart + rayDir * start;
				rayLength = end - start;

				return RayMarch(i, rayStart, rayDir, rayLength);
			}
			ENDCG
		}
				
		// pass 3 - spot light, camera outside
		Pass
		{
			//ZTest Off
			ZTest[_ZTest]
			Cull Back
			ZWrite Off
			Blend One One

			CGPROGRAM
			#pragma vertex vert
			#pragma fragment fragSpotOutside
#pragma target 5.0

			#define UNITY_HDR_ON

			#pragma shader_feature HEIGHT_FOG
			#pragma shader_feature SHADOWS_DEPTH
			#pragma shader_feature SHADOWS_NATIVE
			#pragma shader_feature NOISE
			#pragma shader_feature SPOT

			#ifdef SHADOWS_DEPTH
			#define SHADOWS_NATIVE
			#endif
			
			float _CosAngle;
			float4 _ConeAxis;
			float4 _ConeApex;
			float _PlaneD;

			fixed4 fragSpotOutside(v2f i) : SV_Target
			{
				float2 uv = i.uv.xy / i.uv.w;

				// read depth and reconstruct world position
				float depth = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, uv);

				float3 rayStart = _WorldSpaceCameraPos;
				float3 rayEnd = i.wpos;

				float3 rayDir = (rayEnd - rayStart);
				float rayLength = length(rayDir);

				rayDir /= rayLength;


				// inside cone
				float3 r1 = rayEnd + rayDir * 0.001;

				// plane intersection
				float planeCoord = RayPlaneIntersect(_ConeAxis, _PlaneD, r1, rayDir);
				// ray cone intersection
				float2 lineCoords = RayConeIntersect(_ConeApex, _ConeAxis, _CosAngle, r1, rayDir);

				float z = (LinearEyeDepth(depth) - rayLength);
				rayLength = min(planeCoord, min(lineCoords.x, lineCoords.y));
				rayLength = min(rayLength, z);

				return RayMarch(i, rayEnd, rayDir, rayLength);
			}
			ENDCG
		}

		// pass 4 - scan beam
		Pass
			{
				//ZTest Off
				ZTest [_ZTest]
				Cull Off
				ZWrite Off
				Blend One One

				CGPROGRAM
#pragma vertex vert2
#pragma fragment fragSpotOutside
#pragma target 5.0

#define UNITY_HDR_ON

#pragma shader_feature HEIGHT_FOG
#pragma shader_feature SHADOWS_CUBE
#pragma shader_feature NOISE
#pragma shader_feature POINT
#pragma shader_feature POINT_COOKIE

				sampler2D _CameraGBufferTexture2;

				struct input
				{
					float4 vertex : POSITION;
					float4 normal : NORMAL;
				};

				struct v2f2
				{
					float4 pos : SV_POSITION;
					float4 uv : TEXCOORD0;
					float3 ray : TEXCOORD1;
					float3 wpos : TEXCOORD2;
					float3 normal : NORMAL;
				};

				v2f2 vert2(input v)
				{
					v2f2 o;
					o.pos = mul(_WorldViewProj, v.vertex);
					o.uv = ComputeScreenPos(o.pos);
					o.ray = mul(_WorldView, v.vertex).xyz * float3(-1, -1, 1);
					o.wpos = mul(_Object2World, v.vertex);
					o.normal = mul(_Object2World, float4(v.normal.xyz, 0));
					return o;
				}

				fixed4 fragSpotOutside(v2f2 i) : SV_Target
				{
					float2 uv = i.uv.xy / i.uv.w;

					float4 light = _LightColor;

					// read depth and reconstruct world position
					float depth = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, uv);

					float3 wpos = i.wpos;
					float atten = 0;

					#if defined (POINT) || defined (POINT_COOKIE)
					float3 tolight = wpos - _LightPos.xyz;
					half3 lightDir = -normalize(tolight);

					float att = dot(tolight, tolight) * _LightPos.w;
					atten = tex2D(_LightTextureB0, att.rr).UNITY_ATTEN_CHANNEL;
					atten = 1-att;

					float shadow = saturate(UnityDeferredComputeShadow(tolight, 0, float2(0, 0)) + 0.0f);
					atten *= shadow;
					light *= shadow;
					#endif
					#ifdef NOISE
					float noise = tex3D(_NoiseTexture, frac(wpos * _NoiseData.x + float3(_Time.y * _NoiseVelocity.x, 0, _Time.y * _NoiseVelocity.y)));
					noise = pow(noise, _NoiseData.z) * _NoiseData.y;
					atten *= saturate(noise);
					#endif

					#ifdef HEIGHT_FOG
					float ratio = 1 - saturate((wpos.y - _HeightFog.x) / _HeightFog.y);
					atten *= ratio;
					#endif

					float3 rayDir = normalize(wpos - _WorldSpaceCameraPos);

					float3 tolight2 = normalize(wpos - _LightPos.xyz);
					float cosAngle = dot(tolight2, -rayDir);
					
					float4 c = atten * _LightColor * _VolumetricLight.x * MieScattering(cosAngle);


						half4 gbuffer2 = tex2D(_CameraGBufferTexture2, uv);
						half3 normalWorld = gbuffer2.rgb * 2 - 1;
						normalWorld = normalize(normalWorld);

					float3 planeNormal = normalize(i.normal);

						float d = 1 - abs(dot(planeNormal, normalWorld));
						
					if ((abs(LinearEyeDepth(depth)) - abs(i.ray.z)) < (d * 0.25 + 0.05))
					{ 
						c = light * 1;
					}

					return c;
				}
					ENDCG
			}

		// pass 5 - directional light
		Pass
		{
			ZTest Off
			Cull Front
			ZWrite Off
			Blend One One

			CGPROGRAM

#pragma vertex vert
#pragma fragment fragDir
#pragma target 5.0

#define UNITY_HDR_ON

#pragma shader_feature HEIGHT_FOG
#pragma shader_feature NOISE
#pragma shader_feature SHADOWS_DEPTH
#pragma shader_feature SHADOWS_NATIVE
#pragma shader_feature DIRECTIONAL_COOKIE
#pragma shader_feature DIRECTIONAL

#ifdef SHADOWS_DEPTH
#define SHADOWS_NATIVE
#endif

			fixed4 fragDir(v2f i) : SV_Target
			{
				i.ray = i.ray * (_ProjectionParams.z / i.ray.z);
				float2 uv = i.uv.xy / i.uv.w;
				float depth = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, uv);
					
				float3 rayStart = _WorldSpaceCameraPos;
				float3 rayEnd = i.wpos;

				float3 rayDir = (rayEnd - rayStart);
				float rayLength = length(rayDir);

				rayDir /= rayLength;
				rayLength = min(rayLength, LinearEyeDepth(depth));

				return RayMarch(i, rayStart, rayDir, rayLength);
			}
				ENDCG
		}
	}
}
