#ifndef BALLSIM_H
#define BALLSIM_H
#ifdef __cplusplus
extern "C" {
#endif

/// Plain-data ball state shared between Swift and the C++ simulation core.
typedef struct {
    float position[3];
    float velocity[3];
    float spin[3];          // angular velocity, rad/s, world space
    int   bounces;
    int   bouncesSinceHit;
} BSBall;

typedef struct { float gravity, dragK, magnusK, restitution, tangentialKeep, radius; } BSParams;
typedef struct { float halfLength, netHalfWidth, netHeightCenter, netHeightPost; } BSCourt;

enum { BS_EVENT_NONE = 0, BS_EVENT_BOUNCE = 1, BS_EVENT_NET = 2, BS_EVENT_NET_CORD = 3 };

/// Advances the ball by dt seconds (gravity, drag, Magnus, net, ground bounce). Returns a BS_EVENT_* code.
int BSStepBall(BSBall *ball, float dt, const BSParams *params, const BSCourt *court);

#ifdef __cplusplus
}
#endif
#endif
