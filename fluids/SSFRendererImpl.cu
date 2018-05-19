#include "helper.h"
#include "SSFRendererImpl.h"
#include <GLFW\glfw3.h>
#include <glad\glad.h>
#include <cuda_runtime.h>
#include <helper_cuda.h>
#include <cuda_gl_interop.h>

static float quadVertices[] = { // vertex attributes for a quad that fills the entire screen in Normalized Device Coordinates.
    // positions   // texCoords
    -1.0f,  1.0f,  0.0f, 1.0f,
    -1.0f, -1.0f,  0.0f, 0.0f,
    1.0f, -1.0f,  1.0f, 0.0f,

    -1.0f,  1.0f,  0.0f, 1.0f,
    1.0f, -1.0f,  1.0f, 0.0f,
    1.0f,  1.0f,  1.0f, 1.0f
};

SSFRendererImpl::SSFRendererImpl(Camera *camera, int width, int height)
{
	/* TODO: consider how to handle resolution change */
	this->m_camera = camera;
	this->m_width = width;
	this->m_height = height;
	this->m_pi = camera->getProjectionInfo();

	/* Allocate depth / normal_D / H texture */
	glGenTextures(1, &d_depth);
	glGenTextures(1, &d_depth_r);
	glGenTextures(1, &d_normal_D);
	glGenTextures(1, &d_H);

	glBindTexture(GL_TEXTURE_2D, d_normal_D);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA32F, width, height, 0, GL_RGBA, GL_FLOAT, NULL);
	/* TODO: check effect of GL_NEAREST */
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
	checkGLErr();
	glBindTexture(GL_TEXTURE_2D, d_depth);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_DEPTH_COMPONENT32F, width, height, 0, GL_DEPTH_COMPONENT, GL_FLOAT, NULL);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
	checkGLErr();
	glBindTexture(GL_TEXTURE_2D, d_depth_r);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_R32F, width, height, 0, GL_RED, GL_FLOAT, NULL);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
	checkGLErr();
	glBindTexture(GL_TEXTURE_2D, d_H);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_R32F, width, height, 0, GL_RED, GL_FLOAT, NULL);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
	checkGLErr();

	/* TODO: Bind texture to CUDA resource */
	checkCudaErrors(cudaGraphicsGLRegisterImage(&dcr_normal_D, d_normal_D, GL_TEXTURE_2D, cudaGraphicsRegisterFlagsNone));
	/* CUDA does not support interop with GL_DEPTH_COMPONENT texture ! */
	checkCudaErrors(cudaGraphicsGLRegisterImage(&dcr_depth, d_depth_r, GL_TEXTURE_2D, cudaGraphicsRegisterFlagsNone));
	checkCudaErrors(cudaGraphicsGLRegisterImage(&dcr_H, d_H, GL_TEXTURE_2D, cudaGraphicsRegisterFlagsNone));

	/* Allocate framebuffer & Binding depth texture */
	glGenFramebuffers(1, &d_fbo);
	glBindFramebuffer(GL_FRAMEBUFFER, d_fbo);
	glBindTexture(GL_TEXTURE_2D, d_depth);
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_TEXTURE_2D, d_depth, 0);

	/* Attach one color buffer, this is mandatory */
	uint colorTex;
	glGenTextures(1, &colorTex);
	glBindTexture(GL_TEXTURE_2D, colorTex);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB, width, height, 0, GL_RGB, GL_UNSIGNED_BYTE, NULL);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, colorTex, 0);

	checkFramebufferComplete();
	checkGLErr();

	glBindFramebuffer(GL_FRAMEBUFFER, 0);

	/* Load shaders */
	m_s_get_depth = new Shader(Filename("SSFget_depth_vertex.glsl"), Filename("SSFget_depth_fragment.glsl"));
	fprintf(stderr, "break shader SSFRendererImpl()");
	m_s_put_depth = new Shader(Filename("SSFput_depth_vertex.glsl"), Filename("SSFput_depth_fragment.glsl"));

	/* Load quad vao */
	uint quad_vbo;
	glGenVertexArrays(1, &m_quad_vao);
	glGenBuffers(1, &quad_vbo);
	glBindVertexArray(m_quad_vao);
	glBindBuffer(GL_ARRAY_BUFFER, quad_vbo);
	glBufferData(GL_ARRAY_BUFFER, sizeof(quadVertices), quadVertices, GL_STATIC_DRAW);
	glEnableVertexAttribArray(0);
	glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), (void*)0);
	glEnableVertexAttribArray(1);
	glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), (void*)(2 * sizeof(float)));
}

void SSFRendererImpl::destroy() {
	// if (!dc_depth) return;
	/* TODO */
}

void SSFRendererImpl::renderDepth() {
	/* Render to framebuffer */
	glBindFramebuffer(GL_FRAMEBUFFER, d_fbo);

	m_s_get_depth->use();
	m_camera->use(Shader::now());

	m_s_get_depth->setUnif("pointRadius", 50.f);

	glEnable(GL_DEPTH_TEST);
	glBindVertexArray(p_vao);

	if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE)
		fexit(-1, "Framebuffer not complete\n");

	glClear(GL_DEPTH_BUFFER_BIT);
	glDrawArrays(GL_POINTS, 0, m_nparticle);
	glBindFramebuffer(GL_FRAMEBUFFER, 0);

	glCopyImageSubData(
		d_depth, GL_TEXTURE_2D, 0, 0, 0, 0,
		d_depth_r, GL_TEXTURE_2D, 0, 0, 0, 0,
		m_width, m_height, 1);
	checkGLErr();
}

void SSFRendererImpl::renderPlane() {

	/* Draw depth in greyscale */
	m_s_put_depth->use();
	m_camera->use(Shader::now());

	ProjectionInfo i = m_camera->getProjectionInfo();
	m_s_put_depth->setUnif("projZNear", i.n);
	m_s_put_depth->setUnif("projZFar", i.f);

	glDisable(GL_DEPTH_TEST);
	glBindVertexArray(m_quad_vao);
	glBindTexture(GL_TEXTURE_2D, d_depth_r);
	glDrawArrays(GL_TRIANGLES, 0, 6);
	glEnable(GL_DEPTH_TEST);
}

void SSFRendererImpl::render(uint p_vao, int nparticle) {

	this->p_vao = p_vao;
	this->m_nparticle = nparticle;

	renderDepth();
	renderPlane();
}

void SSFRendererImpl::mapResources() {
	checkCudaErrors(cudaGraphicsMapResources(1, &dcr_depth, 0));
	checkCudaErrors(cudaGraphicsMapResources(1, &dcr_normal_D, 0));
	checkCudaErrors(cudaGraphicsMapResources(1, &dcr_H, 0));

	size_t size;
	checkCudaErrors(cudaGraphicsResourceGetMappedPointer((void**)dc_depth, &size, dcr_depth));
	checkCudaErrors(cudaGraphicsResourceGetMappedPointer((void**)dc_normal_D, &size, dcr_normal_D));
	checkCudaErrors(cudaGraphicsResourceGetMappedPointer((void**)dc_H, &size, dcr_H));
}

void SSFRendererImpl::unmapResources() {
	checkCudaErrors(cudaGraphicsUnmapResources(1, &dcr_depth, 0));
	checkCudaErrors(cudaGraphicsUnmapResources(1, &dcr_normal_D, 0));
	checkCudaErrors(cudaGraphicsUnmapResources(1, &dcr_H, 0));

	/* TODO: check if need unregister resource using cudaGraphicsUnregisterResource() */
}