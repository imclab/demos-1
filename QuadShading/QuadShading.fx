
//--------------------------------------------------------------------------------------
// File: QuadShading.fx
//
// Copyright (c) 2014 Stephen Hill
//--------------------------------------------------------------------------------------

RWTexture2D<uint> lockUAV      : register(u0);
RWTexture2D<uint> overdrawUAV  : register(u1);
RWTexture2D<uint> liveCountUAV : register(u2);
RWTexture1D<uint> liveStatsUAV : register(u3);

Texture2D<uint>   overdrawSRV  : register(t0);
Texture1D<uint>   liveStatsSRV : register(t1);


//--------------------------------------------------------------------------------------
// Constant Buffer Variables
//--------------------------------------------------------------------------------------

cbuffer cbChangeOnResize : register(b0)
{
    matrix Projection;
};

cbuffer cbChangesEveryFrame : register(b1)
{
    matrix View;
};


//--------------------------------------------------------------------------------------
struct GSINPUT
{
    float4 cpos : SV_POSITION;
};

struct PSINPUT
{
    float4 cpos : SV_POSITION;
    float2 col  : TEXCOORD0;
    uint   id   : SV_PrimitiveID;
};


GSINPUT SceneVS(float4 wpos : POSITION)
{
    float4 cpos;
    cpos = mul(wpos, View);
    cpos = mul(cpos, Projection);

    GSINPUT output;
    output.cpos = cpos;

    return output;
}


[maxvertexcount(3)]
void SceneGS(triangle GSINPUT input[3], inout TriangleStream<PSINPUT> output, 
             uint id : SV_PrimitiveID)
{
    PSINPUT p;
    p.id   = id;
    p.cpos = input[0].cpos; p.col = float2(1, 0); output.Append(p);
    p.cpos = input[1].cpos; p.col = float2(0, 1); output.Append(p);
    p.cpos = input[2].cpos; p.col = float2(0, 0); output.Append(p);
    output.RestartStrip();
}

//--------------------------------------------------------------------------------------
void SceneDepthPS(PSINPUT input)
{
}

//--------------------------------------------------------------------------------------
[earlydepthstencil]
void ScenePS(float4 vpos : SV_Position, float2 c0 : TEXCOORD0, uint id : SV_PrimitiveID)
{
    uint2 quad = vpos.xy*0.5;
    uint  prevID;

    uint unlockedID = 0xffffffff;
    bool processed  = false;
    int  lockCount  = 0;
    int  pixelCount = 0;

    for (int i = 0; i < 64; i++)
    {
        if (!processed)
            InterlockedCompareExchange(lockUAV[quad], unlockedID, id, prevID);

        [branch]
        if (prevID == unlockedID)
        {
            if (++lockCount == 4)
            {
                // Retrieve live pixel count (minus 1) in quad
                InterlockedAnd(liveCountUAV[quad], 0, pixelCount);

                // Unlock for other quads
                InterlockedExchange(lockUAV[quad], unlockedID, prevID);
            }
            processed = true;
        }

        if (prevID == id && !processed)
        {
            InterlockedAdd(liveCountUAV[quad], 1);
            processed = true;
        }
    }

    if (lockCount)
    {
        InterlockedAdd(overdrawUAV[quad], 1);
        InterlockedAdd(liveStatsUAV[pixelCount], 1);
    }
}

//--------------------------------------------------------------------------------------
bool InsideTri(float2 c)
{
    return c.x >= 0 && c.y >= 0 && (c.x + c.y <= 1);
}

[earlydepthstencil]
void ScenePS2(float4 vpos : SV_Position, float2 c0 : TEXCOORD0)
{
    // Lowest bits of x and y coordinates, used to adjust the the direction of
    // derivatives and assign the pixel an index within the quad
    uint2 p = uint2(vpos.xy) & 1;

    // Retrieve the barycentric coordinates of the other pixels
    // in the quad. For more details, see:
    // "Shader Amortization using Pixel Quad Message Passing", Eric Penner, GPU Pro 2.
    float2 sign = p ? -1 : 1;
    float2 c1 = c0 + sign.x*ddx_fine(c0);
    float2 c2 = c0 + sign.y*ddy_fine(c0);
    float2 c3 = c2 + sign.x*ddx_fine(c2);

    // Perform triangle inclusion tests for the neighbours
    bool i1 = InsideTri(c1);
    bool i2 = InsideTri(c2);
    bool i3 = InsideTri(c3);

    // Assign an index within the quad:
    // 0 1
    // 2 3
    uint index = p.x + (p.y << 1);

    // Check if all pixels with a lower index are outside of the triangle (i.e. 'dead')
    uint firstAlive = 1;
    if (index & 1) firstAlive &= !i1;
    if (index & 2) firstAlive &= !i2 && !i3;

    // If we're the first live pixel, increment the quad count and update the
    // 'liveness' stats (number of quads with 1-4 live pixels)
    // Note: we don't need to test the liveness of the pixel itself, because writes
    // will fail if it's dead!
    if (firstAlive)
    {
        uint2 quad = vpos.xy*0.5;
        InterlockedAdd(overdrawUAV[quad], 1);

        uint pixelCount = i1 + i2 + i3;
        InterlockedAdd(liveStatsUAV[pixelCount], 1);
    }
}


//--------------------------------------------------------------------------------------
float4 VisVS(float4 pos : POSITION) : SV_Position
{
    return pos;
}


float4 ToColour(uint v)
{
    const uint nbColours = 10;
    const float4 colours[nbColours] =
    {
       float4(0,     0,   0, 255),
       float4(2,    25, 147, 255),
       float4(0,   149, 255, 255),
       float4(0,   253, 255, 255),
       float4(142, 250,   0, 255),
       float4(255, 251,   0, 255),
       float4(255, 147,   0, 255),
       float4(255,  38,   0, 255),
       float4(148,  17,   0, 255),
       float4(255,   0, 255, 255)
    };

    return colours[min(v, nbColours - 1)]/255.0;
}

float4 PieChart(float2 quad)
{
    float t4 = liveStatsSRV[3];
    float t3 = liveStatsSRV[2] + t4;
    float t2 = liveStatsSRV[1] + t3;
    float t1 = liveStatsSRV[0] + t2;

    float4 colour = 0;

    float2 p = quad*0.5 - float2(72, 72);
    if ((p.x*p.x + p.y*p.y) < 64*64)
    {
        float a = t1*(atan2(p.y, p.x + 0.0001)/(2*3.14159265) + 0.5);

             if (a <= t4) colour = ToColour(5);
        else if (a <= t3) colour = ToColour(6);
        else if (a <= t2) colour = ToColour(7);
        else if (a <= t1) colour = ToColour(8);
    }

    return colour;
}

float4 VisPS(float4 vpos : SV_POSITION) : SV_Target
{
    uint2 quad = vpos.xy*0.5;

    uint overdraw = overdrawSRV[quad];
    float4 colour = ToColour(overdraw);

    colour += PieChart(vpos.xy + float2(0.0, 0.0))*0.25;
    colour += PieChart(vpos.xy + float2(0.5, 0.0))*0.25;
    colour += PieChart(vpos.xy + float2(0.0, 0.5))*0.25;
    colour += PieChart(vpos.xy + float2(0.5, 0.5))*0.25;

    return colour;
}