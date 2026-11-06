#include "BallSim.h"
#include <cmath>
#include <algorithm>

namespace {
struct V3 { float x, y, z; };
inline V3 operator+(V3 a, V3 b) { return {a.x + b.x, a.y + b.y, a.z + b.z}; }
inline V3 operator-(V3 a, V3 b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
inline V3 operator*(V3 a, float s) { return {a.x * s, a.y * s, a.z * s}; }
inline V3 cross(V3 a, V3 b) { return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}; }
inline float length(V3 a) { return std::sqrt(a.x * a.x + a.y * a.y + a.z * a.z); }
inline V3 load(const float *p) { return {p[0], p[1], p[2]}; }
inline void store(float *p, V3 v) { p[0] = v.x; p[1] = v.y; p[2] = v.z; }
}

int BSStepBall(BSBall *b, float dt, const BSParams *k, const BSCourt *court) {
    int event = BS_EVENT_NONE;
    V3 pos = load(b->position), vel = load(b->velocity), spin = load(b->spin);

    const float speed = length(vel);
    V3 a = {0, -k->gravity, 0};
    a = a - vel * (k->dragK * speed);
    a = a + cross(spin, vel) * k->magnusK;
    vel = vel + a * dt;
    const V3 prev = pos;
    pos = pos + vel * dt;

    // Net: crossing the z = 0 plane below the (sagging) net height.
    if ((prev.z > 0) != (pos.z > 0) && std::fabs(pos.x) < court->netHalfWidth) {
        const float t = prev.z / (prev.z - pos.z);
        const float y = prev.y + (pos.y - prev.y) * t;
        const float x = prev.x + (pos.x - prev.x) * t;
        const float h = court->netHeightCenter +
            (court->netHeightPost - court->netHeightCenter) * std::min(1.0f, std::fabs(x) / court->netHalfWidth);
        const float clearance = y - k->radius - h;               // > 0: the ball's underside is above the tape
        if (clearance < -0.025f) {                                // solid net: the ball dies and falls back
            pos = {x, y, prev.z > 0 ? k->radius : -k->radius};
            vel.z *= -0.25f;
            vel.x *= 0.5f;
            spin = spin * 0.3f;
            event = BS_EVENT_NET;
        } else if (clearance < 0) {                               // net cord: clips the tape (< 2.5 cm) and trickles over
            pos = {x, y, prev.z > 0 ? -k->radius : k->radius};   // continues in its direction of travel
            vel.z *= 0.45f;
            vel.x *= 0.7f;
            vel.y = std::fmax(vel.y, 0.0f) + 1.6f;
            spin = spin * 0.4f;
            event = BS_EVENT_NET_CORD;
        }
    }

    // Ground bounce with simplified contact-point slip coupling spin and horizontal velocity.
    if (pos.y < k->radius && vel.y < 0) {
        pos.y = k->radius;
        vel.y = -vel.y * k->restitution;
        const V3 contact = V3{vel.x, 0, vel.z} - cross(spin, V3{0, -k->radius, 0});
        const V3 slip = contact * 0.12f;
        vel.x = vel.x * k->tangentialKeep - slip.x * 0.2f;
        vel.z = vel.z * k->tangentialKeep - slip.z * 0.2f;
        spin = spin * 0.7f;
        b->bounces += 1; b->bouncesSinceHit += 1;
        if (length(vel) < 0.05f) vel = {0, 0, 0};
        event = BS_EVENT_BOUNCE;
    }
    store(b->position, pos); store(b->velocity, vel); store(b->spin, spin);
    return event;
}
